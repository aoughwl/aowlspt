/* aowlspt_overlay.h — an in-game overlay for post-1.0 Tarkov, drawn by hand.
 *
 * Pre-1.0, an in-game menu was `OnGUI` and Unity's IMGUI drew it for you. That
 * route is gone: IL2CPP has no managed assemblies, so there is no `MonoBehaviour`
 * to attach and no `GUI.Window` to call. Every BepInEx-era overlay — including
 * every "config manager" mod — is built on that and none of them can load.
 *
 * The honest replacement is to draw the panel ourselves. The game renders
 * through D3D11, so a hook on `IDXGISwapChain::Present` gives a callback once
 * per frame with the device, the immediate context and the back buffer in hand
 * — after the game has finished its frame and before the flip. That is exactly
 * where an overlay belongs, and it is what Steam, Discord and RivaTuner all do.
 *
 * ------------------------------------------------------------------------
 * How the vtable is found, and why not by pattern scan
 * ------------------------------------------------------------------------
 * A COM interface pointer is a pointer to a vtable, and every `IDXGISwapChain`
 * created by the same `dxgi.dll` shares one. So the address of the real
 * `Present` can be read out of *any* swap chain — including a 1x1 one we create
 * ourselves on a hidden window, use for nothing, and release immediately. That
 * is the whole trick: no signature scan, no version-specific offsets, nothing
 * that breaks when the game or the driver updates. `aowl_ov_capture_vtable`
 * below is ten lines and is correct by construction.
 *
 * A pattern scan for the Present prologue would also work and is what a lot of
 * cheat-adjacent code does. It is strictly worse: it depends on the bytes of a
 * Microsoft DLL that Windows Update changes underneath you, and when it goes
 * wrong it detours the middle of an unrelated function.
 *
 * The detour itself is `abi/aowlspt_detour.h` — the same engine `AowlHostApi.patch`
 * uses on IL2CPP methods, unmodified. It is used through `aowl_hook_install`
 * rather than `aowl_hook_attach`, because attach claims a slot in the fixed
 * thunk pool that mods' patches draw from; the overlay has its own detour
 * functions with the right signatures already, so it needs no thunk and takes
 * nothing from that pool.
 *
 * ------------------------------------------------------------------------
 * Render state: what is touched and what is put back
 * ------------------------------------------------------------------------
 * Drawing inside Present means drawing on a context whose entire state belongs
 * to the game. Everything below is backed up before the overlay's draw and
 * restored after it, and every `*Get*` call is paired with a `Release` because
 * the D3D11 getters AddRef what they hand back — the classic version of this
 * bug leaks one device object per frame and takes the process down after a few
 * hours, which reads as "the game leaks memory in raid".
 *
 *   IA: input layout, vertex buffer 0, index buffer, primitive topology
 *   VS: shader + class instances, constant buffer 0
 *   PS: shader + class instances, shader resource 0, sampler 0
 *   GS: shader + class instances;  HS/DS: shader only — see below
 *   RS: rasteriser state, viewports, scissor rects
 *   OM: blend state + factor + mask, depth-stencil state + ref,
 *       all 8 render targets + depth-stencil view
 *
 * The GS/HS/DS entry is the one that is easy to skip and fatal to skip. We do
 * not *set* those stages, but the game's last draw may have left a geometry or
 * tessellation shader bound, and it would then run on our two triangles with an
 * input signature it was never written for. So they are explicitly nulled and
 * then restored.
 *
 * Not covered, and said plainly rather than left to be discovered: stream
 * output targets (`SOSetTargets`), unordered access views bound through
 * `OMSetRenderTargetsAndUnorderedAccessViews`, and compute state. None of the
 * three affects our draw; a game that has stream output bound across Present
 * would see it survive, because we never touch it.
 *
 * ------------------------------------------------------------------------
 * Failure policy
 * ------------------------------------------------------------------------
 * A crash in a Present hook takes the game down mid-raid, so every failure here
 * latches instead. `g_ov.broken` is set on any unrecoverable error and from
 * that point both detours are a straight tail call to the original — the hook
 * stays installed (removing it from inside itself is its own hazard) and the
 * game renders exactly as it would with no overlay at all. `aowl_ov_status`
 * reports why, so it shows up in the host log rather than as a black screen.
 *
 * ------------------------------------------------------------------------
 * Threads
 * ------------------------------------------------------------------------
 *   render thread   the hooked Present. Draws. Reads the mod list under a lock.
 *                   Never blocks: no HTTP, no file IO, no allocation after the
 *                   first frame.
 *   window thread   the hooked WndProc. Records input into atomics.
 *   worker thread   polls the backend over HTTP and posts toggles. Owns every
 *                   blocking call on the steady-state path. The exception is
 *                   teardown: `aowl_ov_stop` runs on the host thread and both
 *                   waits on the worker and sleeps out the render thread.
 *
 * Most of what is shared between them -- the `AowlOvMod` table, the lists,
 * entries, issues and results tables, the wrapper scalars and the mod-sync body
 * -- is under `g_ov.cs`, and the command queue with it. The key ring is the one
 * deliberate exception, single-producer/single-consumer between the window and
 * render threads and outside the lock; see the note above it for why.
 */

#ifndef AOWLSPT_OVERLAY_H
#define AOWLSPT_OVERLAY_H

#ifndef COBJMACROS
#define COBJMACROS          /* C-callable COM: ID3D11Device_CreateBuffer(...) */
#endif
#ifndef CINTERFACE
#define CINTERFACE
#endif

#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>       /* strtod, for a float control's value */
#include <stdarg.h>
#include <stddef.h>       /* offsetof, for the theme key table */

#include "aowlspt_detour.h"
#include "aowlspt_admin.h"   /* the admin/cheat HUD's shared-memory surface */
#include "aowlspt_region.h"  /* the SHARED per-frame region: every mod's draw */
/* The cursor-free facility, PURE half only: this module needs the panel BITS
 * and nothing else. The live half calls `UnityEngine.Cursor` and depends on the
 * host's prologue snapshot, neither of which exists over here -- and must not,
 * because managed calls belong on Unity's main thread and this is the render
 * thread. Including the real header rather than re-typing two constants is
 * deliberate: a duplicated bit value that drifts is a mask that silently stops
 * matching. See `aowl_ov_publish_cursor_panels` below. */
#define AOWL_CUR_PURE 1
#include "aowlspt_cursor.h"

/* The admin/cheat HUD's shared region, mapped in `aowl_ov_start`. NULL until
 * then, and NULL forever if the OS refuses the mapping -- in which case every
 * admin draw below is a no-op and the game is untouched. The mod (mods/admin)
 * maps the same region by name and publishes the projected ESP frame + toggles
 * into it; this file only reads it and draws. */
static AowlAdminShared* g_ov_admin = NULL;

/* ================================================================== *
 * Public surface
 * ================================================================== */

#define AOWL_OV_MAX_MODS     64
#define AOWL_OV_MAX_CMDS     32
/* How many edits may be in flight at once. Bounded on purpose (rule 4): a
 * player can outrun the pipeline, and the answer to the 9th simultaneous edit
 * is a REFUSAL THAT SAYS SO, never a silent drop. */
#define AOWL_OV_PEND_MAX     8
#define AOWL_OV_MAX_LISTS    16
#define AOWL_OV_MAX_ENTRIES 160   /* list entries, flattened across all lists */
#define AOWL_OV_MAX_ISSUES   24   /* registry problems + excluded decisions   */
#define AOWL_OV_MAX_RESULTS  40   /* per-mod outcomes from one apply/toggle   */
#define AOWL_OV_KEYS         32   /* the wndproc -> render thread key ring    */

/* The mod-sync feed's buffer. It holds one whole response body and nothing is
 * acted on unless the body is whole, so the size is the ceiling on how many
 * mods the backend can describe -- about two hundred rows at seventy bytes
 * each. A body that does not fit is **dropped outright**: the worker reads into
 * a 32 KB stack buffer and refuses to publish anything whose length is not
 * under this bound, so the previous serial stands and the host keeps doing what
 * it was already doing. That is a whole-body test rather than a parse, which is
 * the point -- half a feed applied to loaded code is the failure this guards.
 * (This used to describe a truncation losing its terminating key and being
 * rejected by the reader. The reader never sees it.) */
/* MEASURED 2026-09-04, curl against the live backend on port 80 with
 * `Accept-Encoding: identity` (which this file already sends, and which the
 * backend honours):
 *   /aowlspt/settings/index          960 bytes
 *   /aowlspt/settings/index/full 569,247 bytes
 *   /aowlspt/settings/aowl.tarkov  434,140 bytes
 *   /aowlspt/settings/aowl.sain     51,846 bytes
 *   /aowlspt/settings/aowl.maps     31,854 bytes
 * At 16,384 every one of those but the compact index and the small pages was
 * DROPPED, and dropped SILENTLY -- the host saw only "5 request(s) and none
 * returned a body here", which reads as a missing route and is not one. The
 * read buffer above it (`AOWL_OV_HTTP_BUF`) has been 1 MiB for a while; this
 * bound was the only thing still refusing whole, correct bodies. Matched to it
 * deliberately: two bounds on one path that disagree is how this hid. The
 * drop is also RECORDED now (`aowl_ov_sync_drop_reason`) so that a body
 * refused for being too large can never again present as a network problem. */
#define AOWL_OV_SYNC_MAX 1048576   /* == AOWL_OV_HTTP_BUF, defined below */

/* One row of the panel. Fixed-size fields rather than pointers: the render
 * thread reads this table every frame and a pointer into a string the worker
 * thread might be reallocating is a use-after-free waiting for a slow HTTP
 * response.
 *
 * `verdict`, `reason`, `from` and `explicit` are the manager's own words about
 * this row and are copied through untouched. The overlay does not compose a
 * sentence about why a mod is or is not loading -- `mgr/resolve.nim` already
 * decided that, in one place, against the rules written down in
 * `registry/README.md`, and a second opinion invented here could only ever
 * disagree with it. */
typedef struct AowlOvMod {
    char    guid[80];
    char    name[64];
    char    version[24];
    int32_t enabled;    /* the desired state, as the manager resolves it      */
    int32_t loaded;     /* 1 when it is actually running                      */
    int32_t pending;    /* clicked, and the server has not confirmed yet      */
    int32_t restart;    /* the manager says this one only changes on restart  */
    int32_t hostPushed; /* the host told us about this row itself             */
    char    verdict[24];/* loaded | disabled | not-selected | conflict | ...  */
    char    reason[160];/* the manager's sentence, verbatim                   */
    char    from[64];   /* the list (or "override") that last decided it      */
    int32_t explicitOv; /* you decided it, rather than a list -- clearable    */
    int32_t liveKnown;  /* `live` came back as a bool rather than null        */
    int32_t backendRow; /* the manager answered about this guid               */
    int32_t protectedRow;/* the manager will not let this one be switched off  */
    int32_t order;      /* load position, or -1                              */
    /* --- what the *client* host said about this guid ---------------------
     *
     * `clientKnown` is the only one of these that may be read on its own, and
     * every other field here is meaningless without it. It is 1 exactly when
     * the manager's last answer carried `clientLive` for this row, which the
     * manager sends only where it holds a record from the game's host.
     *
     * Absence is **not** a negative. A row with `clientKnown == 0` is a row the
     * client host has said nothing about, and there are three unrelated reasons
     * for that -- the report arrives in instalments and this row is in a later
     * one (`clientMore`), the report was complete and this mod is simply not
     * one the client side is asked about, or no report has arrived at all
     * (`clientHost`). None of them is "it is not loaded", and the panel draws
     * all three apart. See `mods/manager/mgr/clientreport.nim`, which is where
     * the same rule is enforced on the other side. */
    int32_t clientKnown;
    int32_t clientLive;    /* it is loaded in the game process right now      */
    int32_t clientWant;    /* what the *client* resolution asked of it        */
    char    clientOutcome[12];/* settled|changed|skipped|refused|on-restart   */
    char    clientCode[24];/* the slug, on skipped/refused/on-restart only    */
} AowlOvMod;

/* One named list out of the registry, and one entry inside one. Entries are a
 * single flat table with an index back to the list rather than a nested array
 * per list: everything the render thread walks has to be a fixed-size table it
 * can memcpy out from under one lock. */
typedef struct AowlOvList {
    char    id[64];
    char    name[48];
    char    desc[224];
    char    inherits[96];   /* comma-joined, because it is only ever printed */
    int32_t active;         /* in the manager's `active` set right now       */
    int32_t entries;        /* how many rows of the entry table are ours     */
} AowlOvList;

typedef struct AowlOvEntry {
    int32_t list;           /* index into the list table                     */
    char    id[64];
    int32_t enabled;
    char    note[112];
} AowlOvEntry;

/* Something wrong, from `/aowlspt/mods/conflicts`: either a registry-level
 * problem (a bare sentence) or a mod that was excluded and why. */
typedef struct AowlOvIssue {
    char id[64];            /* "" for a registry-level problem */
    char verdict[24];
    char text[176];
} AowlOvIssue;

/* One line of an apply's answer: what the manager asked the host to do about
 * one mod, and what the host said back. */
typedef struct AowlOvResult {
    char id[64];
    char action[10];        /* load | unload            */
    char outcome[12];       /* applied|requested|deferred|refused */
    char message[176];
} AowlOvResult;

/* `loaded` has three sources and they are not equal in authority.
 *
 * `hostPushed` marks the rows the host handed us through `aowl_ov_set_mod` --
 * this process talking about its own library table, which is a fact the process
 * cannot be wrong about at the moment it is said. The backend's `live` field is
 * the *manager's* answer, and a backend that sends `"live":null` (nobody who
 * could answer has answered) leaves every row's `loaded` exactly where it was.
 *
 * The manager's `live` used to be a guess about anything running in the game:
 * it runs on the server side and had never heard of a client-only mod, so a
 * host-pushed row ignored it outright. That is no longer true. The client host
 * now reports what became of every mod it was asked about, the manager holds
 * the ledger (`mgr/clientreport.nim`) and folds it into `live`, and it says so
 * per row by sending `clientLive`. So:
 *
 *   - a row carrying `clientLive` has been answered for by the game's own host,
 *     and its `live` may lower a host-pushed row. It is the same process
 *     speaking, one poll later, and later wins.
 *   - a row *not* carrying it is a row the manager has no client record for,
 *     and its `live` still may not lower a host-pushed one -- that is the old
 *     rule, kept for exactly the case it was written for.
 *
 * Getting this backwards in one direction greys out every client-side mod the
 * moment the panel reaches a backend, which looks precisely like the overlay
 * deciding nothing is loaded. Getting it backwards in the other leaves a mod
 * the host has just unloaded reading `running yes` for the rest of the session,
 * which is the one thing on this panel a player has no way to check. */

/* Called on the *worker* thread after a toggle has been **attempted**, so the
 * host can react without polling. It fires whether or not the backend answered
 * -- the failure path sets the error line and leaves the row's `~` up, and the
 * callback still runs -- so a host that treats it as "this was accepted" is
 * reading more into it than it says. Optional; may be left NULL. */
typedef void (*AowlOvToggleFn)(const char* guid, int32_t enabled, void* user);

static int32_t aowl_ov_start(int32_t toggleVk, int32_t backendPort);
static void    aowl_ov_stop(void);
static int32_t aowl_ov_running(void);
static int32_t aowl_ov_visible(void);
static void    aowl_ov_set_visible(int32_t on);
static int32_t aowl_ov_frames(void);
static int32_t aowl_ov_status(char* buf, int32_t cap);
static void    aowl_ov_set_mod(const char* guid, const char* name,
                               const char* version, int32_t enabled);
static void    aowl_ov_clear_mods(void);
static void    aowl_ov_on_toggle(AowlOvToggleFn fn, void* user);

/* ---- what one frame of the panel costs --------------------------------
 *
 * The overlay runs inside the game's present loop, so its cost is not a
 * curiosity: it is subtracted from the frame budget of a game people play
 * competitively. These are measured with QPC around the build-and-draw, on the
 * render thread, and they cost three QPC reads per drawn frame to keep -- it
 * was one pair until the build and the draw were split apart, so that
 * `avgBuildNs` could say which half the time went to.
 *
 * `avg` is an exponential moving average over roughly the last hundred frames;
 * `max` is the worst single frame since the overlay started, which is the one
 * that shows up as a stutter. Both are 0 until the panel has been drawn -- and
 * they are **not** reset when it is closed again: only `aowl_ov_start` zeroes
 * them, so after a close they keep reporting the last thing that was measured.
 * A hidden frame is cheap but it is not free: the frame counter, the `inDraw`
 * guard and `aowl_ov_bind` all run before the visible test. This used to say
 * both figures were 0 while the panel was closed and that a hidden panel was
 * one `if`; neither was quite the case.
 *
 * Keeping them across a close is the point rather than an oversight: what a
 * player wants is the cost of the panel they had open in a raid, read out of
 * the log afterwards, and zeroing on close would hand them a 0 for exactly
 * that question. The price is that a *reopened* panel reads out the previous
 * opening's numbers, which the title bar labels `was` until this opening has
 * put `AOWL_OV_COST_SETTLE` frames into the average. A caller sampling these
 * two functions has the same question and the same answer is available: they
 * are live only if the panel has been open for more than half a second. */
static int32_t aowl_ov_frame_ns(void);
/* The integer factor the panel is drawn at: 1 below about 1300 lines, 2 above,
 * 3 above 2500. The font is an 8x16 atlas sampled POINT/CLAMP, so an integer
 * factor is exact -- every texel becomes an NxN block of identical pixels and
 * the glyphs stay as crisp as they are at 1x. A fractional scale would need a
 * filter and would turn 8x16 Consolas into grey mush. */
static int32_t aowl_ov_scale(void);
static int32_t aowl_ov_frame_ns_max(void);

/* ---- the mod-sync feed -------------------------------------------------
 *
 * The panel above is a *view*: it shows what the backend decided and it draws
 * a button. The feed is the other direction of the same wire -- the client
 * host asking the backend, on a slow timer, "which mods should be running on
 * this side", so that it can make itself match while the game runs.
 *
 * It lives here rather than in the host for one reason: the worker thread and
 * `aowl_ov_http` already exist, already poll on a timer, and are already the
 * one HTTP client inside the game process. A second one in nimony would mean a
 * second thread, `aowlspt_net` linked into a DLL injected mid-startup, and two
 * pieces of code that could disagree about whether the backend is reachable.
 *
 * The feed is deliberately dumb. It fetches, it checks nothing but the
 * transport, and it hands the body over verbatim; every decision about whether
 * the body is usable is made by the host, off this thread. What it does
 * guarantee is that a body is handed over *whole or not at all*: a fetch that
 * failed, returned nothing, or came back deflated leaves the previous body in
 * place and does not bump the serial, so the host sees no change rather than a
 * truncated one.
 *
 * `aowl_ov_sync_start` may be called before or after the render side is up,
 * and works either way -- see the note in `aowl_ov_start` about why the worker
 * thread no longer depends on the swap chain. */
static void    aowl_ov_sync_start(const char* path, int32_t intervalMs);
static int32_t aowl_ov_sync_pending(void);
static int32_t aowl_ov_sync_take(char* out, int32_t cap);
static int32_t aowl_ov_sync_drop_reason(int32_t* lastLen, int32_t* wasZlib);
static int32_t aowl_ov_sync_attempts(void);

/* The write leg. `aowl_ov_post_start` arms one path+body; the worker sends it
 * on its own thread (never the caller's) and `aowl_ov_post_take` returns the
 * response once, non-blocking, same shape as the GET feed above. */
static void    aowl_ov_post_start(const char* path, const char* body);
static int32_t aowl_ov_post_pending(void);
static int32_t aowl_ov_take_edit_kick(void);
static int32_t aowl_ov_post_take(char* out, int32_t cap, int32_t* ok);
/* 0 = idle, 1 = armed and NOT YET SENT by the worker, 2 = sent and awaiting a
 * response. `aowl_ov_post_pending` collapses 1 and 2 into "busy", which is
 * exactly the distinction a stalled caller needs in order to name a cause
 * instead of saying "never came back". */
static int32_t aowl_ov_post_stage(void);

/* --- THE PER-MOD ENABLE LEG, for the native MODS tab -------------------
 *
 * CORRECTING A CLAIM THIS REPOSITORY CARRIED IN WRITING. `settingsbind.nim`
 * and `docs/MOD-ENABLE-PATH.md` said the mod-enable write is
 * `GET /aowlspt/mods/enable|disable/<guid>` and that closing the gap needed a
 * one-shot GET on this bridge. MEASURED against the two instruments that
 * settle it -- `mods/manager/manager.nim:2295-2306` (the route table) and the
 * command leg of this file's own worker loop -- that is NOT what the F12 mod
 * manager does. F12 queues `AOWL_CMD_TOGGLE`, which sends
 * `POST /aowlspt/mods/toggle/<guid>` with `{"enabled":true|false}` and takes
 * the manager's `toggleLocked` path (absolute state when `enabled` is present,
 * protected-row refusal, `afterChange()` broadcast, the reply row). The
 * enable/disable GETs are a DIFFERENT, older route (`overrideLocked`).
 *
 * So a native ENABLED switch that must do "exactly what the F12 mod manager
 * does" needs no new HTTP verb here at all: it needs to enter the SAME command
 * queue, which is what these two do. `aowl_ov_mod_toggle` is
 * `aowl_ov_panel_toggle`'s body with the flip removed -- a switch on a settings
 * screen carries the state the player chose, and flipping whatever the table
 * last held would race the 1 s panel poll.
 *
 * Three states, never two. `aowl_ov_mod_enabled` returns:
 *    1 / 0  the manager's own answer for this guid
 *      -2   a row exists, but the manager has not answered about it, so the
 *           value is only this process's report of what it loaded
 *      -1   no row at all -- nothing is known, which is not "disabled"
 * `aowl_ov_mod_toggle` returns 1 queued, 0 no such row, -1 protected (the
 * manager would refuse it anyway), -2 no backend is configured. */
static int32_t aowl_ov_mod_enabled(const char* guid);
static int32_t aowl_ov_mod_pending(const char* guid);
static int32_t aowl_ov_mod_toggle(const char* guid, int32_t enabled);
/* Sends the armed POST, if any, and publishes its outcome. Extracted from the
 * worker loop so that ANY long-running worker-thread routine can pump it --
 * see `aowl_ov_settings_verify`, which waits on progress that only this leg
 * can produce. WORKER THREAD ONLY (it owns the static request buffer). */
static void    aowl_ov_pump_post(void);

/* ================================================================== *
 * Baked assets
 *
 * Both tables are generated by `tests/overlayhost/fontgen.c` and
 * `tests/overlayhost/shadergen.c` and pasted here. Nothing at runtime reads a
 * file, compiles a shader or talks to GDI: inside a game process, the fewer
 * subsystems an overlay wakes up on its first frame, the fewer ways that frame
 * has to be the last one.
 * ================================================================== */

static const uint8_t aowl_ov_font[95][16] = {
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 32 */
  {0x00,0x00,0x00,0x10,0x10,0x10,0x10,0x10,0x10,0x00,0x18,0x18,0x00,0x00,0x00,0x00}, /* 33 */
  {0x00,0x00,0x00,0x6C,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 34 */
  {0x00,0x00,0x00,0x00,0x24,0x24,0xFE,0x24,0x48,0xFE,0x48,0x48,0x00,0x00,0x00,0x00}, /* 35 */
  {0x00,0x00,0x00,0x10,0x38,0x50,0x50,0x30,0x18,0x14,0x24,0x78,0x20,0x20,0x00,0x00}, /* 36 */
  {0x00,0x00,0x00,0xE2,0xA4,0xA8,0xE8,0x10,0x2E,0x2A,0x4A,0x8E,0x00,0x00,0x00,0x00}, /* 37 */
  {0x00,0x00,0x00,0x30,0x48,0x48,0x58,0x30,0x54,0x9C,0x8C,0x7E,0x00,0x00,0x00,0x00}, /* 38 */
  {0x00,0x00,0x00,0x18,0x18,0x18,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 39 */
  {0x00,0x00,0x00,0x08,0x10,0x10,0x20,0x20,0x20,0x20,0x20,0x20,0x10,0x10,0x08,0x00}, /* 40 */
  {0x00,0x00,0x00,0x20,0x10,0x10,0x08,0x08,0x08,0x08,0x08,0x08,0x10,0x10,0x20,0x00}, /* 41 */
  {0x00,0x00,0x00,0x10,0x54,0x38,0x54,0x10,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 42 */
  {0x00,0x00,0x00,0x00,0x00,0x10,0x10,0x10,0xFE,0x10,0x10,0x10,0x00,0x00,0x00,0x00}, /* 43 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x18,0x30,0x00,0x00}, /* 44 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 45 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x30,0x30,0x00,0x00,0x00,0x00}, /* 46 */
  {0x00,0x00,0x00,0x04,0x08,0x08,0x08,0x10,0x10,0x20,0x20,0x20,0x40,0x00,0x00,0x00}, /* 47 */
  {0x00,0x00,0x00,0x00,0x3C,0x26,0x46,0x4A,0x52,0x62,0x64,0x3C,0x00,0x00,0x00,0x00}, /* 48 */
  {0x00,0x00,0x00,0x00,0x30,0x50,0x10,0x10,0x10,0x10,0x10,0x7C,0x00,0x00,0x00,0x00}, /* 49 */
  {0x00,0x00,0x00,0x00,0x38,0x44,0x04,0x04,0x08,0x10,0x20,0x7C,0x00,0x00,0x00,0x00}, /* 50 */
  {0x00,0x00,0x00,0x00,0x78,0x04,0x04,0x38,0x04,0x04,0x04,0x78,0x00,0x00,0x00,0x00}, /* 51 */
  {0x00,0x00,0x00,0x00,0x18,0x38,0x28,0x48,0x88,0xFE,0x08,0x08,0x00,0x00,0x00,0x00}, /* 52 */
  {0x00,0x00,0x00,0x00,0x7C,0x40,0x40,0x78,0x04,0x04,0x0C,0x78,0x00,0x00,0x00,0x00}, /* 53 */
  {0x00,0x00,0x00,0x00,0x1C,0x20,0x40,0x5C,0x62,0x42,0x42,0x3C,0x00,0x00,0x00,0x00}, /* 54 */
  {0x00,0x00,0x00,0x00,0x7E,0x02,0x04,0x0C,0x08,0x18,0x10,0x30,0x00,0x00,0x00,0x00}, /* 55 */
  {0x00,0x00,0x00,0x00,0x38,0x44,0x64,0x38,0x6C,0x44,0x44,0x38,0x00,0x00,0x00,0x00}, /* 56 */
  {0x00,0x00,0x00,0x00,0x3C,0x42,0x42,0x46,0x3A,0x02,0x04,0x38,0x00,0x00,0x00,0x00}, /* 57 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00,0x00,0x00,0x00}, /* 58 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x18,0x30,0x00,0x00}, /* 59 */
  {0x00,0x00,0x00,0x00,0x00,0x04,0x18,0x30,0x60,0x30,0x18,0x04,0x00,0x00,0x00,0x00}, /* 60 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x7C,0x00,0x7C,0x00,0x00,0x00,0x00,0x00,0x00}, /* 61 */
  {0x00,0x00,0x00,0x00,0x00,0x40,0x30,0x18,0x0C,0x18,0x30,0x40,0x00,0x00,0x00,0x00}, /* 62 */
  {0x00,0x00,0x00,0x30,0x0C,0x04,0x04,0x38,0x20,0x00,0x30,0x30,0x00,0x00,0x00,0x00}, /* 63 */
  {0x00,0x00,0x00,0x3C,0x64,0x42,0x5A,0xAA,0xAA,0xAA,0xAA,0xBC,0x80,0x40,0x38,0x00}, /* 64 */
  {0x00,0x00,0x00,0x00,0x18,0x28,0x28,0x24,0x64,0x7E,0x42,0x42,0x00,0x00,0x00,0x00}, /* 65 */
  {0x00,0x00,0x00,0x00,0x78,0x44,0x44,0x78,0x44,0x44,0x44,0x78,0x00,0x00,0x00,0x00}, /* 66 */
  {0x00,0x00,0x00,0x00,0x1C,0x20,0x40,0x40,0x40,0x40,0x60,0x3C,0x00,0x00,0x00,0x00}, /* 67 */
  {0x00,0x00,0x00,0x00,0x78,0x44,0x42,0x42,0x42,0x42,0x44,0x78,0x00,0x00,0x00,0x00}, /* 68 */
  {0x00,0x00,0x00,0x00,0x7C,0x40,0x40,0x7C,0x40,0x40,0x40,0x7C,0x00,0x00,0x00,0x00}, /* 69 */
  {0x00,0x00,0x00,0x00,0x7C,0x40,0x40,0x7C,0x40,0x40,0x40,0x40,0x00,0x00,0x00,0x00}, /* 70 */
  {0x00,0x00,0x00,0x00,0x3C,0x40,0x80,0x9C,0x84,0x84,0x44,0x3C,0x00,0x00,0x00,0x00}, /* 71 */
  {0x00,0x00,0x00,0x00,0x44,0x44,0x44,0x7C,0x44,0x44,0x44,0x44,0x00,0x00,0x00,0x00}, /* 72 */
  {0x00,0x00,0x00,0x00,0x7C,0x10,0x10,0x10,0x10,0x10,0x10,0x7C,0x00,0x00,0x00,0x00}, /* 73 */
  {0x00,0x00,0x00,0x00,0x78,0x08,0x08,0x08,0x08,0x08,0x08,0x70,0x00,0x00,0x00,0x00}, /* 74 */
  {0x00,0x00,0x00,0x00,0x44,0x48,0x50,0x50,0x60,0x50,0x48,0x44,0x00,0x00,0x00,0x00}, /* 75 */
  {0x00,0x00,0x00,0x00,0x40,0x40,0x40,0x40,0x40,0x40,0x40,0x7C,0x00,0x00,0x00,0x00}, /* 76 */
  {0x00,0x00,0x00,0x00,0x44,0x64,0x6C,0x6E,0x56,0x46,0xC6,0xC6,0x00,0x00,0x00,0x00}, /* 77 */
  {0x00,0x00,0x00,0x00,0x64,0x64,0x64,0x54,0x54,0x4C,0x4C,0x4C,0x00,0x00,0x00,0x00}, /* 78 */
  {0x00,0x00,0x00,0x00,0x3C,0x44,0x82,0x82,0x82,0x82,0x44,0x78,0x00,0x00,0x00,0x00}, /* 79 */
  {0x00,0x00,0x00,0x00,0x78,0x44,0x44,0x44,0x78,0x40,0x40,0x40,0x00,0x00,0x00,0x00}, /* 80 */
  {0x00,0x00,0x00,0x00,0x78,0x4C,0x84,0x84,0x84,0x84,0xC8,0x78,0x20,0x1C,0x00,0x00}, /* 81 */
  {0x00,0x00,0x00,0x00,0x78,0x44,0x44,0x44,0x78,0x4C,0x44,0x46,0x00,0x00,0x00,0x00}, /* 82 */
  {0x00,0x00,0x00,0x00,0x38,0x40,0x40,0x30,0x08,0x04,0x04,0x78,0x00,0x00,0x00,0x00}, /* 83 */
  {0x00,0x00,0x00,0x00,0x7C,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x00,0x00,0x00,0x00}, /* 84 */
  {0x00,0x00,0x00,0x00,0x42,0x42,0x42,0x42,0x42,0x42,0x42,0x3C,0x00,0x00,0x00,0x00}, /* 85 */
  {0x00,0x00,0x00,0x00,0x82,0x82,0xC4,0x44,0x6C,0x28,0x28,0x30,0x00,0x00,0x00,0x00}, /* 86 */
  {0x00,0x00,0x00,0x00,0x44,0x44,0x44,0x54,0x54,0x54,0x6C,0x6C,0x00,0x00,0x00,0x00}, /* 87 */
  {0x00,0x00,0x00,0x00,0xC6,0x44,0x28,0x38,0x38,0x28,0x44,0xC6,0x00,0x00,0x00,0x00}, /* 88 */
  {0x00,0x00,0x00,0x00,0x82,0x44,0x6C,0x28,0x10,0x10,0x10,0x10,0x00,0x00,0x00,0x00}, /* 89 */
  {0x00,0x00,0x00,0x00,0x7E,0x04,0x04,0x08,0x10,0x20,0x20,0x7C,0x00,0x00,0x00,0x00}, /* 90 */
  {0x00,0x00,0x00,0x38,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x20,0x38,0x00}, /* 91 */
  {0x00,0x00,0x00,0x40,0x20,0x20,0x20,0x10,0x10,0x08,0x08,0x08,0x04,0x00,0x00,0x00}, /* 92 */
  {0x00,0x00,0x00,0x38,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x38,0x00}, /* 93 */
  {0x00,0x00,0x00,0x00,0x10,0x28,0x44,0x44,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 94 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFE,0x00}, /* 95 */
  {0x00,0x00,0x00,0x60,0x30,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* 96 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x38,0x04,0x3C,0x44,0x4C,0x3C,0x00,0x00,0x00,0x00}, /* 97 */
  {0x00,0x00,0x00,0x40,0x40,0x40,0x78,0x64,0x44,0x44,0x44,0x78,0x00,0x00,0x00,0x00}, /* 98 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x60,0x40,0x40,0x60,0x3C,0x00,0x00,0x00,0x00}, /* 99 */
  {0x00,0x00,0x00,0x04,0x04,0x04,0x3C,0x44,0x44,0x44,0x4C,0x34,0x00,0x00,0x00,0x00}, /* 100 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x42,0x7E,0x40,0x60,0x3E,0x00,0x00,0x00,0x00}, /* 101 */
  {0x00,0x00,0x00,0x0E,0x10,0x10,0x7C,0x10,0x10,0x10,0x10,0x10,0x00,0x00,0x00,0x00}, /* 102 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3E,0x44,0x44,0x78,0x40,0x7C,0x42,0x42,0x3C,0x00}, /* 103 */
  {0x00,0x00,0x00,0x40,0x40,0x40,0x58,0x64,0x44,0x44,0x44,0x44,0x00,0x00,0x00,0x00}, /* 104 */
  {0x00,0x00,0x00,0x18,0x18,0x00,0x70,0x10,0x10,0x10,0x10,0x7C,0x00,0x00,0x00,0x00}, /* 105 */
  {0x00,0x00,0x00,0x18,0x18,0x00,0x78,0x08,0x08,0x08,0x08,0x08,0x08,0x08,0x70,0x00}, /* 106 */
  {0x00,0x00,0x00,0x40,0x40,0x40,0x4C,0x58,0x60,0x50,0x48,0x44,0x00,0x00,0x00,0x00}, /* 107 */
  {0x00,0x00,0x00,0x70,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x7C,0x00,0x00,0x00,0x00}, /* 108 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0xFE,0xDA,0x92,0x92,0x92,0x92,0x00,0x00,0x00,0x00}, /* 109 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x78,0x64,0x44,0x44,0x44,0x44,0x00,0x00,0x00,0x00}, /* 110 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x66,0x42,0x42,0x66,0x3C,0x00,0x00,0x00,0x00}, /* 111 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x78,0x64,0x44,0x44,0x44,0x78,0x40,0x40,0x40,0x00}, /* 112 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x44,0x44,0x44,0x4C,0x34,0x04,0x04,0x04,0x00}, /* 113 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x5C,0x64,0x40,0x40,0x40,0x40,0x00,0x00,0x00,0x00}, /* 114 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x3C,0x40,0x70,0x0C,0x04,0x78,0x00,0x00,0x00,0x00}, /* 115 */
  {0x00,0x00,0x00,0x00,0x20,0x20,0xFC,0x20,0x20,0x20,0x20,0x3C,0x00,0x00,0x00,0x00}, /* 116 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x44,0x44,0x44,0x44,0x4C,0x3C,0x00,0x00,0x00,0x00}, /* 117 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x44,0x44,0x6C,0x28,0x28,0x10,0x00,0x00,0x00,0x00}, /* 118 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x44,0x54,0x54,0x5C,0x6C,0x24,0x00,0x00,0x00,0x00}, /* 119 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x66,0x2C,0x18,0x28,0x64,0xC6,0x00,0x00,0x00,0x00}, /* 120 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x44,0x44,0x68,0x28,0x28,0x10,0x10,0x20,0xE0,0x00}, /* 121 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x7C,0x08,0x10,0x10,0x20,0x7C,0x00,0x00,0x00,0x00}, /* 122 */
  {0x00,0x00,0x00,0x0C,0x10,0x10,0x10,0x10,0x60,0x10,0x10,0x10,0x10,0x10,0x0C,0x00}, /* 123 */
  {0x00,0x00,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x10,0x00}, /* 124 */
  {0x00,0x00,0x00,0x60,0x10,0x10,0x10,0x10,0x0C,0x10,0x10,0x10,0x10,0x10,0x60,0x00}, /* 125 */
  {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x64,0xB4,0x98,0x00,0x00,0x00,0x00,0x00,0x00}, /* 126 */
};

static const uint8_t aowl_ov_vs[816] = {
  0x44, 0x58, 0x42, 0x43, 0xF2, 0x2B, 0x4F, 0x0D, 0xB5, 0x47, 0x14, 0xB9,
  0x42, 0xFE, 0x87, 0x19, 0xEC, 0x91, 0xE7, 0xF9, 0x01, 0x00, 0x00, 0x00,
  0x30, 0x03, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00,
  0xEC, 0x00, 0x00, 0x00, 0x5C, 0x01, 0x00, 0x00, 0xD0, 0x01, 0x00, 0x00,
  0xB4, 0x02, 0x00, 0x00, 0x52, 0x44, 0x45, 0x46, 0xB0, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x1C, 0x00, 0x00, 0x00, 0x00, 0x04, 0xFE, 0xFF, 0x00, 0x81, 0x00, 0x00,
  0x88, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x43, 0x62, 0x00, 0xAB, 0x3C, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x58, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x10, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x73, 0x63, 0x61, 0x6C, 0x65, 0x00, 0xAB, 0xAB,
  0x01, 0x00, 0x03, 0x00, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x4D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x6F, 0x66,
  0x74, 0x20, 0x28, 0x52, 0x29, 0x20, 0x48, 0x4C, 0x53, 0x4C, 0x20, 0x53,
  0x68, 0x61, 0x64, 0x65, 0x72, 0x20, 0x43, 0x6F, 0x6D, 0x70, 0x69, 0x6C,
  0x65, 0x72, 0x20, 0x31, 0x30, 0x2E, 0x31, 0x00, 0x49, 0x53, 0x47, 0x4E,
  0x68, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
  0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00,
  0x59, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00,
  0x62, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x0F, 0x00, 0x00,
  0x50, 0x4F, 0x53, 0x49, 0x54, 0x49, 0x4F, 0x4E, 0x00, 0x54, 0x45, 0x58,
  0x43, 0x4F, 0x4F, 0x52, 0x44, 0x00, 0x43, 0x4F, 0x4C, 0x4F, 0x52, 0x00,
  0x4F, 0x53, 0x47, 0x4E, 0x6C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x08, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x0F, 0x00, 0x00, 0x00, 0x5C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x03, 0x0C, 0x00, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x0F, 0x00, 0x00, 0x00, 0x53, 0x56, 0x5F, 0x50, 0x4F, 0x53, 0x49, 0x54,
  0x49, 0x4F, 0x4E, 0x00, 0x54, 0x45, 0x58, 0x43, 0x4F, 0x4F, 0x52, 0x44,
  0x00, 0x43, 0x4F, 0x4C, 0x4F, 0x52, 0x00, 0xAB, 0x53, 0x48, 0x44, 0x52,
  0xDC, 0x00, 0x00, 0x00, 0x40, 0x00, 0x01, 0x00, 0x37, 0x00, 0x00, 0x00,
  0x59, 0x00, 0x00, 0x04, 0x46, 0x8E, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x03, 0x32, 0x10, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x03, 0x32, 0x10, 0x10, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x5F, 0x00, 0x00, 0x03, 0xF2, 0x10, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x67, 0x00, 0x00, 0x04, 0xF2, 0x20, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03,
  0x32, 0x20, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03,
  0xF2, 0x20, 0x10, 0x00, 0x02, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x0B,
  0x32, 0x20, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46, 0x10, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x46, 0x80, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0xE6, 0x8A, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x08, 0xC2, 0x20, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x02, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3F,
  0x36, 0x00, 0x00, 0x05, 0x32, 0x20, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x46, 0x10, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x05,
  0xF2, 0x20, 0x10, 0x00, 0x02, 0x00, 0x00, 0x00, 0x46, 0x1E, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x01, 0x53, 0x54, 0x41, 0x54,
  0x74, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
 
};

static const uint8_t aowl_ov_ps[668] = {
  0x44, 0x58, 0x42, 0x43, 0x73, 0xC0, 0xDB, 0x2E, 0x7F, 0xB0, 0x75, 0x43,
  0xFD, 0xB5, 0x01, 0xF3, 0xEB, 0xED, 0x64, 0xC0, 0x01, 0x00, 0x00, 0x00,
  0x9C, 0x02, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00,
  0xC8, 0x00, 0x00, 0x00, 0x3C, 0x01, 0x00, 0x00, 0x70, 0x01, 0x00, 0x00,
  0x20, 0x02, 0x00, 0x00, 0x52, 0x44, 0x45, 0x46, 0x8C, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x1C, 0x00, 0x00, 0x00, 0x00, 0x04, 0xFF, 0xFF, 0x00, 0x81, 0x00, 0x00,
  0x64, 0x00, 0x00, 0x00, 0x5C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
  0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x73, 0x6D, 0x70, 0x00,
  0x74, 0x65, 0x78, 0x00, 0x4D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x6F, 0x66,
  0x74, 0x20, 0x28, 0x52, 0x29, 0x20, 0x48, 0x4C, 0x53, 0x4C, 0x20, 0x53,
  0x68, 0x61, 0x64, 0x65, 0x72, 0x20, 0x43, 0x6F, 0x6D, 0x70, 0x69, 0x6C,
  0x65, 0x72, 0x20, 0x31, 0x30, 0x2E, 0x31, 0x00, 0x49, 0x53, 0x47, 0x4E,
  0x6C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
  0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00,
  0x5C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00,
  0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x0F, 0x00, 0x00,
  0x53, 0x56, 0x5F, 0x50, 0x4F, 0x53, 0x49, 0x54, 0x49, 0x4F, 0x4E, 0x00,
  0x54, 0x45, 0x58, 0x43, 0x4F, 0x4F, 0x52, 0x44, 0x00, 0x43, 0x4F, 0x4C,
  0x4F, 0x52, 0x00, 0xAB, 0x4F, 0x53, 0x47, 0x4E, 0x2C, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x53, 0x56, 0x5F, 0x54,
  0x61, 0x72, 0x67, 0x65, 0x74, 0x00, 0xAB, 0xAB, 0x53, 0x48, 0x44, 0x52,
  0xA8, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00,
  0x5A, 0x00, 0x00, 0x03, 0x00, 0x60, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x58, 0x18, 0x00, 0x04, 0x00, 0x70, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x55, 0x55, 0x00, 0x00, 0x62, 0x10, 0x00, 0x03, 0x32, 0x10, 0x10, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x62, 0x10, 0x00, 0x03, 0xF2, 0x10, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03, 0xF2, 0x20, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x00,
  0x45, 0x00, 0x00, 0x09, 0xF2, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x46, 0x10, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x46, 0x7E, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x38, 0x00, 0x00, 0x07, 0x82, 0x20, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x0A, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A, 0x10, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x36, 0x00, 0x00, 0x05, 0x72, 0x20, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x46, 0x12, 0x10, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x3E, 0x00, 0x00, 0x01, 0x53, 0x54, 0x41, 0x54, 0x74, 0x00, 0x00, 0x00,
  0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/* The SECOND pixel shader, for AOWL_REGION_CMD_QUAD -- textured, tinted.
 * `aowl_ov_ps` above samples `.r` only, which is right for an R8 font atlas
 * and discards every colour channel of a map tile. Generated by the same
 * `tests/overlayhost/shadergen.c` and pasted, like the other two. */
static const uint8_t aowl_ov_ps_tex[648] = {
  0x44, 0x58, 0x42, 0x43, 0x3A, 0x5F, 0xF3, 0xB9, 0x96, 0xC0, 0x74, 0xD1,
  0xD2, 0x18, 0x6B, 0x6E, 0xD8, 0xE1, 0x7C, 0x70, 0x01, 0x00, 0x00, 0x00,
  0x88, 0x02, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x34, 0x00, 0x00, 0x00,
  0xC8, 0x00, 0x00, 0x00, 0x3C, 0x01, 0x00, 0x00, 0x70, 0x01, 0x00, 0x00,
  0x0C, 0x02, 0x00, 0x00, 0x52, 0x44, 0x45, 0x46, 0x8C, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x1C, 0x00, 0x00, 0x00, 0x00, 0x04, 0xFF, 0xFF, 0x00, 0x81, 0x00, 0x00,
  0x64, 0x00, 0x00, 0x00, 0x5C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
  0x04, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x0D, 0x00, 0x00, 0x00, 0x73, 0x6D, 0x70, 0x00,
  0x74, 0x65, 0x78, 0x00, 0x4D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x6F, 0x66,
  0x74, 0x20, 0x28, 0x52, 0x29, 0x20, 0x48, 0x4C, 0x53, 0x4C, 0x20, 0x53,
  0x68, 0x61, 0x64, 0x65, 0x72, 0x20, 0x43, 0x6F, 0x6D, 0x70, 0x69, 0x6C,
  0x65, 0x72, 0x20, 0x31, 0x30, 0x2E, 0x31, 0x00, 0x49, 0x53, 0x47, 0x4E,
  0x6C, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
  0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00,
  0x5C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x00,
  0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x0F, 0x0F, 0x00, 0x00,
  0x53, 0x56, 0x5F, 0x50, 0x4F, 0x53, 0x49, 0x54, 0x49, 0x4F, 0x4E, 0x00,
  0x54, 0x45, 0x58, 0x43, 0x4F, 0x4F, 0x52, 0x44, 0x00, 0x43, 0x4F, 0x4C,
  0x4F, 0x52, 0x00, 0xAB, 0x4F, 0x53, 0x47, 0x4E, 0x2C, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x53, 0x56, 0x5F, 0x54,
  0x61, 0x72, 0x67, 0x65, 0x74, 0x00, 0xAB, 0xAB, 0x53, 0x48, 0x44, 0x52,
  0x94, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x25, 0x00, 0x00, 0x00,
  0x5A, 0x00, 0x00, 0x03, 0x00, 0x60, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x58, 0x18, 0x00, 0x04, 0x00, 0x70, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x55, 0x55, 0x00, 0x00, 0x62, 0x10, 0x00, 0x03, 0x32, 0x10, 0x10, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x62, 0x10, 0x00, 0x03, 0xF2, 0x10, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x65, 0x00, 0x00, 0x03, 0xF2, 0x20, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x00,
  0x45, 0x00, 0x00, 0x09, 0xF2, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x46, 0x10, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x46, 0x7E, 0x10, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x60, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x38, 0x00, 0x00, 0x07, 0xF2, 0x20, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x46, 0x0E, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46, 0x1E, 0x10, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x3E, 0x00, 0x00, 0x01, 0x53, 0x54, 0x41, 0x54,
  0x74, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
 
};


/* Glyph cells are 8x16. The atlas is 16 cells wide and 6 rows tall (95 glyphs,
 * ASCII 32..126), plus one extra row that holds a single fully-opaque texel.
 * Solid quads sample that texel, which is why there is one shader and one
 * pipeline state for both rectangles and text rather than two of each. */
#define AOWL_OV_CW    8
#define AOWL_OV_CH    16
#define AOWL_OV_ATW   128
#define AOWL_OV_ATH   112   /* 6*16 glyph rows + a 16px row for the white texel */
#define AOWL_OV_WHITE_U (0.5f / (float)AOWL_OV_ATW)
#define AOWL_OV_WHITE_V ((96.0f + 0.5f) / (float)AOWL_OV_ATH)

#define AOWL_RGBA(r, g, b, a) \
    ((uint32_t)((uint32_t)(r) | ((uint32_t)(g) << 8) | \
                ((uint32_t)(b) << 16) | ((uint32_t)(a) << 24)))

/* ================================================================== *
 * State
 * ================================================================== */

/* One contiguous run of vertices drawn with one PS and one SRV. `srv == NULL`
 * means the font atlas and the coverage shader -- the old, only, behaviour. */
typedef struct AowlOvSpan {
    int32_t                   start;
    int32_t                   count;
    ID3D11ShaderResourceView* srv;   /* NULL -> font atlas + coverage PS */
} AowlOvSpan;

/* One cached tile on the GPU. */
typedef struct AowlOvTexEntry {
    uint64_t                  key;
    int32_t                   gen;
    int64_t                   lastFrame;
    ID3D11ShaderResourceView* srv;
} AowlOvTexEntry;

typedef struct AowlOvVert {
    float    x, y;      /* pixels, top-left origin */
    float    u, v;
    uint32_t col;       /* R8G8B8A8_UNORM, so low byte is red */
} AowlOvVert;

/* 4096 quads. A full manager screen -- 18 rows, a six-line detail pane, a
 * wrapped reason and two legend lines -- is about 1,300 glyphs plus 60 solid
 * quads, so this is a margin of roughly 3x and it is a flat 480 KB of .bss that
 * is never reallocated. Overflow is dropped by `aowl_ov_vert` rather than
 * grown: the render thread does not allocate. */
#define AOWL_OV_MAX_VERTS 24576

/* Spans, and the GPU tile cache.
 *
 * 64 spans: a map draw submits its tiles in key order, so consecutive quads on
 * the same tile coalesce into one span and a full screen of a 32-tile working
 * set cannot exceed 33 spans even in the worst interleaving with panel text.
 * Overflow COALESCES INTO THE LAST SPAN rather than dropping geometry -- the
 * result is a tile drawn with the wrong texture, which is visible, versus a
 * hole, which reads as "the map did not load". Both are wrong; the visible one
 * gets reported. It is also counted.
 *
 * AOWL_OV_TEX_MAX mirrors AOWL_REGION_TEX_MAX exactly: the GPU cache can never
 * usefully be smaller than the CPU table feeding it, and making it larger just
 * holds SRVs for slots that no longer exist. */
#define AOWL_OV_MAX_SPANS 64
#define AOWL_OV_TEX_MAX   AOWL_REGION_TEX_MAX

/* What the render thread asks the worker thread to do. Every one of these is a
 * request the manager already serves; none of them is a state change the
 * overlay makes on its own. */
typedef enum AowlOvCmdKind {
    AOWL_CMD_TOGGLE = 0,   /* POST /toggle/<id> {"enabled":..}  */
    AOWL_CMD_CLEAR,        /* GET  /clear/<id>                  */
    AOWL_CMD_SELECT,       /* GET  /select/<list-id>            */
    AOWL_CMD_APPLY,        /* GET  /apply                       */
    AOWL_CMD_RELOAD,       /* GET  /reload                      */
    AOWL_CMD_SPAGE,        /* GET  a settings page's controls   */
    AOWL_CMD_SSET          /* POST one settings edit            */
} AowlOvCmdKind;

typedef struct AowlOvCmd {
    int32_t kind;
    char    guid[80];      /* the mod id, or the list id, or the page id */
    int32_t enabled;       /* the bool arg, or isMod for a settings page */
    /* Only the settings commands use these. `SPAGE` leaves them empty; `SSET`
     * carries the one row it is changing, as its key and a JSON literal. */
    char    skey[80];
    char    sval[96];
} AowlOvCmd;

/* Which pane is on screen. */
typedef enum AowlOvView {
    AOWL_VIEW_MODS = 0,
    AOWL_VIEW_LISTS,
    AOWL_VIEW_ISSUES,
    AOWL_VIEW_APPLY,
    /* The two logs, interleaved and filtered -- see THE LOGS SCREEN below.
     * Appended rather than inserted: `sel`/`top` are indexed by view and the
     * numeric jump keys are positional, so a new view in the middle would
     * silently move somebody's muscle memory. */
    AOWL_VIEW_LOGS,
    AOWL_VIEW_COUNT
} AowlOvView;

/* The mods view's filter, cycled with F. Nothing here is typed: a text field
 * inside a game whose window is swallowing keystrokes is a way to lose a
 * keypress into a chat box, and a four-way cycle answers the questions people
 * actually ask of a mod list. */
typedef enum AowlOvFilter {
    AOWL_FILTER_ALL = 0,
    AOWL_FILTER_LOADING,
    AOWL_FILTER_EXCLUDED,
    AOWL_FILTER_OVERRIDDEN,
    AOWL_FILTER_COUNT
} AowlOvFilter;

/* ================================================================== *
 * THE LOGS SCREEN
 *
 * A fifth manager view that shows the two logs this install writes -- the
 * backend's (`aowlspt-backend.log`, the SERVER) and the host's
 * (`aowlspt-host.log`, the CLIENT) -- interleaved in the order they were
 * read, filterable by source, by level, by which mod or subsystem wrote the
 * line, and by a typed search term.
 *
 * WHY IT READS FILES AND NOT HTTP. "The backend died" is precisely the moment
 * somebody opens the logs, and a log screen that needs the backend to be up in
 * order to show you why the backend went down is not a log screen. Both files
 * sit next to this DLL in the install directory, and the game process can open
 * them directly -- so this whole feature works with the port dead, exactly as
 * the synthetic `aowl.panel` settings page does.
 *
 * WHAT BOUNDS THE COST. Never a whole file: `aowlspt-backend.log` carries PROBE
 * lines several kilobytes long and grows without limit during a session. The
 * worker thread (never the render thread) opens each file at most once every
 * AOWL_OV_LOG_POLL_MS, and only while the screen is actually being drawn; on
 * the first read it seeks to at most AOWL_OV_LOG_TAIL bytes from the end, and
 * every read after that takes at most AOWL_OV_LOG_CHUNK new bytes. Lines land
 * in a fixed ring of AOWL_OV_LOG_MAX entries -- the oldest are dropped, and the
 * count of what was dropped is printed rather than hidden. The render thread
 * re-derives the filtered index only when something it depends on has changed
 * (`logFiltStamp`), so a still frame walks nothing at all.
 *
 * THE FACET RULE, stated so it can be argued with. A line's facet is the first
 * whitespace-delimited word of its message WHEN THAT WORD ENDS IN A COLON --
 * `sain:`, `debugui:`, `botdiag:`, `manager:`, `morebots:`, `config:` -- with
 * the colon stripped and the rest lowercased. Anything else is `system`. The
 * word must be 2..AOWL_OV_LOG_FACETLEN-1 characters, must contain a letter, and
 * must be made only of letters, digits, `.`, `_` and `-`; a token that fails
 * any of those is not a facet and the line is `system`.
 *
 * MEASURED against 326 host lines and 2,496 backend lines from a live run:
 * the rule finds sain, FOV, config, debugui, botdiag, region, deep-probe,
 * manager, morebots, singleplayer and leaves REQ, route, subscribed, loaded,
 * profile and prose lines under `system`, which is what one wants.
 *
 * WHAT IT FAILS ON, and this is not hypothetical:
 *   * A mod that prefixes with a SPACE and no colon is invisible to it. The
 *     brief named `graphics` as such a prefix; every `graphics` line in the
 *     sampled run lands under `system`, and there is no way for this rule to
 *     know that `graphics` is a mod and `subscribed` is a verb.
 *   * The same subsystem writing both `botdiag:` and `botdiag ` produces ONE
 *     facet and a set of `system` lines, not two facets.
 *   * A line whose message happens to begin with a colon-terminated word that
 *     is not a mod -- `capability:`, `ids:`, `g_Airdrop_PlaneAirdropFlareWait:`
 *     -- becomes a facet of its own. Three such appeared in the 2,496-line
 *     sample. They are harmless (one extra entry in the facet cycle) and they
 *     are the honest cost of not hardcoding a mod list.
 *   * Continuation lines (a stack trace, a wrapped message) have no `[t]`
 *     prefix at all. They keep the level `?` and the facet `system` rather than
 *     inheriting the line above, because inheriting would be a guess.
 * ================================================================== */

#define AOWL_OV_LOG_MAX      1200   /* lines held, across BOTH sources */
#define AOWL_OV_LOG_TEXT      196   /* per line, including the terminator */
#define AOWL_OV_LOG_FACETS     64
#define AOWL_OV_LOG_FACETLEN   20
#define AOWL_OV_LOG_TAIL   262144   /* how far back the FIRST read looks */
#define AOWL_OV_LOG_CHUNK   65536   /* new bytes taken per source per poll */
#define AOWL_OV_LOG_POLL_MS   400
/* Consecutive open/read failures before a source switches itself off and says
 * so. The same self-disable every other overlay feature has: a log file that
 * cannot be opened must cost one line of explanation, not a syscall a frame. */
#define AOWL_OV_LOG_MAXFAIL    10

enum { AOWL_LOG_SERVER = 0, AOWL_LOG_CLIENT = 1, AOWL_LOG_SRCS = 2 };

/* `?` is a real state and not a synonym for info: a line whose level could not
 * be read must not be coloured as though it had been. */
enum { AOWL_LOGLVL_UNKNOWN = 0, AOWL_LOGLVL_OK, AOWL_LOGLVL_INFO,
       AOWL_LOGLVL_WARN, AOWL_LOGLVL_ERR, AOWL_LOGLVL_COUNT };

/* The source filter. `ALL` first, so the default shows everything. */
enum { AOWL_LOGSRC_ALL = 0, AOWL_LOGSRC_SERVER, AOWL_LOGSRC_CLIENT,
       AOWL_LOGSRC_COUNT };

/* The facet filter is not an enum: -2 is every facet, -1 is `system` (lines
 * with no mod prefix), and >= 0 is an index into `logFacets`. */
#define AOWL_LOG_FACET_ALL    (-2)
#define AOWL_LOG_FACET_SYSTEM (-1)

typedef struct AowlOvLogLine {
    char    text[AOWL_OV_LOG_TEXT];  /* the WHOLE line, prefix included */
    int32_t src;                     /* AOWL_LOG_SERVER | AOWL_LOG_CLIENT */
    int32_t lvl;                     /* AOWL_LOGLVL_*                     */
    int32_t facet;                   /* index, or AOWL_LOG_FACET_SYSTEM   */
    int32_t msgAt;                   /* offset of the message in `text`   */
} AowlOvLogLine;

/* ================================================================== *
 * Settings mode
 *
 * The overlay has a second face: the revamped in-game settings screen the F12
 * key is really for. The mod-manager views above answer "what is loaded"; this
 * answers "what can I change". It is a left-hand page nav -- one page per loaded
 * mod, then the whole SPT server config surface -- and a right-hand column of
 * controls drawn from the schema each page serves. The two faces share every
 * primitive (the vertex buffer, the font, the input ring, the worker) and are
 * switched with the header toggle or F2.
 *
 * The schema comes over the same worker thread as everything else: a mod's page
 * is `GET /aowlspt/settings/<guid>` (a mod already serves its own declared
 * schema there, current values folded in), and the SPT pages come from the
 * settings hub -- an index at `/aowlspt/settings/spt/index` and one page at
 * `/aowlspt/settings/spt/page/<id>`. An edit on an implemented row POSTs the one
 * key back to the mod's page, which persists it into `config.json`; every SPT
 * row, and every mod row a mod flagged `implemented:false`, is drawn greyed with
 * a NOT-IMPL badge and cannot be changed, because nothing behind it would act on
 * the change yet. That honesty is a hard requirement, not a nicety. */

/* The worker's one HTTP body buffer. Sized off the largest body any route this
 * panel fetches actually produces, with room to grow: 283,798 bytes measured
 * today for `aowl.tarkov`'s 802-row schema, so 1 MiB is a little over 3x. It is
 * `static` inside the worker rather than on its stack -- a megabyte on a thread
 * stack is not affordable, a megabyte in `.bss` is. A body that STILL does not
 * fit now says so (`lastTrunc`) instead of being reported as a bad schema. */
#define AOWL_OV_HTTP_BUF     1048576
/* The write leg's body buffer. It was 512, which is ample for the one-row edit
 * the panel sends and far too small for the other direction: the client host
 * publishes a client-only mod's WHOLE schema up to the backend over this slot
 * (`host/Aowlspt.Host.Il2Cpp/settingsbridge.nim`), because a mod loaded in the
 * game process has no HTTP route of its own. `aowl_ov_copy` truncates rather
 * than refusing, and half a schema parses as a short schema, so the caller is
 * required to check the length against this before arming -- which it does. */
#define AOWL_OV_POST_BODY    65536

#define AOWL_OV_MAX_SPAGES   48    /* mod pages + 28 SPT pages + margin */
#define AOWL_OV_MAX_SITEMS   1200  /* controls on the one loaded page   */
#define AOWL_OV_MAX_SCATS    96    /* distinct categories on that page  */
#define AOWL_OV_MAX_NAV      (AOWL_OV_MAX_SPAGES + AOWL_OV_MAX_SCATS)
#define AOWL_OV_SOPT_MAX     10    /* enum choices kept per control     */

typedef enum AowlOvSKind {
    AOWL_S_BOOL = 0,
    AOWL_S_INT,
    AOWL_S_FLOAT,
    AOWL_S_ENUM,
    AOWL_S_STRING,
    AOWL_S_KEYBIND,
    AOWL_S_NESTED      /* an SPT list/dict, listed for completeness, raw only */
} AowlOvSKind;

/* One page in the left nav. `isMod` decides where its controls are fetched
 * from; `count`/`done` come from the index so the nav can show "3/6 done"
 * without loading the page. -1 means the index did not say. */
typedef struct AowlOvSPage {
    char    id[80];
    char    label[48];
    int32_t isMod;
    int32_t count;
    int32_t done;
} AowlOvSPage;

/* One control. Fixed-size, like every other table the render thread walks: the
 * worker fills it under the lock and the render thread reads a snapshot. `raw`
 * is the value as a JSON literal (`1.5`, `true`, `"M"`) -- what an edit POSTs
 * back -- and `value` is the same thing formatted for the row. */
/* THE THREE DISPLAY STATES OF AN EDITED ROW.
 *
 * Deliberately the same three outcomes the verify ladder already produces, in
 * the same words, so the row badge and the banner can never disagree:
 *   NONE      nothing in flight -- the row shows the served value
 *   SAVING    the player's value, not yet confirmed (verify still running)
 *   REJECTED  verify said NOT APPLIED -- the row shows the AUTHORITATIVE value
 *             and says the edit was not accepted
 *   UNKNOWN   verify said INCONCLUSIVE -- authoritative value, and says so
 * There is no fourth state meaning "probably fine". A row that cannot be
 * confirmed says it cannot be confirmed. */
enum {
    AOWL_OV_PEND_NONE = 0,
    AOWL_OV_PEND_SAVING,
    AOWL_OV_PEND_REJECTED,
    AOWL_OV_PEND_UNKNOWN
};

typedef struct AowlOvSItem {
    char    key[80];
    char    label[64];
    int32_t kind;
    char    value[64];
    char    raw[64];
    float   lo, hi, step;
    int32_t hasRange;
    char    opts[AOWL_OV_SOPT_MAX][28];
    int32_t optCount;
    char    category[64];
    char    subcat[64];
    /* The GROUP PATH, '/'-joined, to arbitrary depth -- "Player/Health/Regen".
     * Taken from the row's `path` array when the backend sends one
     * (`aowl/src/aowlspt/settings.nim` `settingPath`), and otherwise derived
     * here from `category` and `subcat` by the identical rule, so a backend
     * that predates `path` groups exactly as it always did. Empty segments are
     * dropped on both routes: a stray separator must never produce a group with
     * no name, which is the defect this whole path business exists to make
     * unrepresentable. `depth` is the number of segments; 0 means ungrouped and
     * the row lands under "General". */
    char    path[160];
    int32_t depth;
    char    desc[192];
    int32_t implemented;
    /* THE AUTHORITATIVE VALUE, and it is NOT `raw`.
     *
     * `raw` is what the row DISPLAYS. Once an optimistic edit is in flight the
     * panel paints the value the player asked for, so `raw` is theirs and not
     * the server's -- and a verify that compared `raw` against what it had
     * just written would be comparing a value with itself. That is the check
     * that cannot fail, which is the shape of every defect this screen has
     * had. `auth` is set ONLY by `aowl_ov_sval_display`, straight off the
     * parsed document, and `aowl_ov_pend_apply` never touches it. Everything
     * that asks "did it take?" reads `auth`. */
    char    auth[64];
    /* Which of the three display states this row is in -- AOWL_OV_PEND_*. */
    int32_t pend;
} AowlOvSItem;

/* One second-level tab on the loaded page. `items` is SORTED by category (see
 * `aowl_ov_sort_items`), so a category is a contiguous half-open range and a
 * sub-tab is a filter that costs two integers rather than an index table --
 * which is why `selItem`/`editItem`/`dragItem` stay item indices and every edit
 * path below is untouched by this. */
/* ONE edit in flight. See `AowlOvState::opt`. */
typedef struct AowlOvPend {
    char    page[80];   /* page the edit belongs to ("" = none)     */
    char    key[80];    /* the row's key                            */
    char    raw[64];    /* the JSON literal the player asked for    */
    int32_t state;      /* AOWL_OV_PEND_*                           */
} AowlOvPend;

typedef struct AowlOvSCat {
    char    label[64];   /* the LAST segment -- what the nav row prints */
    char    full[160];   /* the whole path -- what the breadcrumb prints */
    int32_t depth;       /* 1-based; 1 is a top-level group               */
    int32_t parent;      /* index of the node one segment shorter, or -1  */
    int32_t lo, hi;      /* [lo,hi) into items -- the WHOLE subtree       */
    int32_t direct;      /* rows sitting exactly at `full`, not deeper    */
} AowlOvSCat;

typedef struct AowlOvState {
    /* --- lifecycle --- */
    volatile LONG started;
    volatile LONG broken;
    volatile LONG inDraw;        /* re-entrancy guard for the Present hook */
    char          status[256];

    /* --- hooks --- */
    void* presentHook;
    void* resizeHook;
    void* presentOrig;
    void* resizeOrig;

    /* --- window --- */
    HWND      hwnd;
    WNDPROC   oldProc;

    /* --- device objects, all owned by us --- */
    IDXGISwapChain*         swap;
    ID3D11Device*           dev;
    ID3D11DeviceContext*    ctx;
    ID3D11RenderTargetView* rtv;
    ID3D11VertexShader*     vs;
    ID3D11PixelShader*      ps;
    ID3D11PixelShader*      psTex;      /* textured quads; see aowl_ov_ps_tex */
    ID3D11InputLayout*      layout;
    ID3D11Buffer*           vb;
    ID3D11Buffer*           cb;
    ID3D11BlendState*       blend;
    ID3D11RasterizerState*  rast;
    ID3D11DepthStencilState* depth;
    ID3D11ShaderResourceView* font;
    ID3D11SamplerState*     samp;

    UINT bbW, bbH;

    /* --- input --- */
    int32_t       toggleVk;
    volatile LONG visible;
    volatile LONG mx, my;
    volatile LONG clickDown;     /* set by WM_LBUTTONDOWN, cleared on consume */
    volatile LONG mouseHeld;     /* the left button is down right now (for sliders) */
    volatile LONG cursorLocked;  /* the game is using raw input; we integrate deltas */
    volatile LONG wheel;         /* accumulated WM_MOUSEWHEEL notches */

    /* The keyboard, as a single-producer/single-consumer ring. The window
     * thread writes and the render thread reads, and neither ever waits on the
     * other: a wndproc that blocks on a lock the render thread holds is a
     * window that stops answering while the game is busy, which Windows shows
     * the player as "not responding". */
    LONG          keys[AOWL_OV_KEYS];
    volatile LONG keyHead, keyTail;

    /* --- data --- */
    CRITICAL_SECTION cs;
    AowlOvMod        mods[AOWL_OV_MAX_MODS];
    int32_t          modCount;
    AowlOvList       lists[AOWL_OV_MAX_LISTS];
    int32_t          listCount;
    AowlOvEntry      entries[AOWL_OV_MAX_ENTRIES];
    int32_t          entryCount;
    AowlOvIssue      issues[AOWL_OV_MAX_ISSUES];
    int32_t          issueCount;
    AowlOvResult     results[AOWL_OV_MAX_RESULTS];
    int32_t          resultCount;
    AowlOvCmd        cmds[AOWL_OV_MAX_CMDS];
    int32_t          cmdCount;

    /* --- settings mode, worker side (under `cs`) --- */
    AowlOvSPage      pages[AOWL_OV_MAX_SPAGES];    /* the merged nav: mods then SPT */
    int32_t          pageCount;
    AowlOvSPage      sptPages[AOWL_OV_MAX_SPAGES]; /* the SPT half, as the hub gave it */
    int32_t          sptPageCount;
    int32_t          sptGot;        /* the SPT index has answered at least once */
    /* The settings INDEX -- `GET /aowlspt/settings/index`, one entry per mod
     * that has actually called `declareSettings`. This, and not the mod
     * roster, is what the nav is built from: the roster lists everything the
     * registry knows about, including the manager, the settings hub itself and
     * the fallback UI, none of which a player can configure and all of which
     * used to occupy a page that then failed to load. The filter is structural
     * -- "did this mod publish a schema" -- not a list of names to hide. */
    AowlOvSPage      idxMods[AOWL_OV_MAX_SPAGES];
    int32_t          idxModCount;
    int32_t          idxGot;        /* the index has answered at least once */
    char             idxWhy[192];   /* why it has not, when it has not */
    AowlOvSItem      items[AOWL_OV_MAX_SITEMS];    /* the one loaded page's controls */
    int32_t          itemCount;
    char             itemsPage[80]; /* which page id `items` holds ("" = none)   */
    volatile LONG    lastTrunc;     /* nonzero: the last body did not fit, in bytes */
    int32_t          itemsErr;      /* the last page fetch failed */
    /* WHY the last page fetch failed, in the words the player needs. Empty when
     * `itemsErr` is 0. A body that was too big for the worker buffer used to be
     * indistinguishable here from a 404 and from a mod that is not loaded, and
     * all three read as "the mod may not be loaded" -- which sent one session
     * looking at the registry for a fault that was a 32 KB buffer. */
    char             itemsWhy[192];
    /* THE OPTIMISTIC EDIT -- the one edit currently in flight, if any.
     *
     * MEASURED (facts #204, #210): the write pipeline is healthy and takes
     * 13.7 s. `sbCollect()` snapshots the rows BEFORE the sync whose reply
     * drains the edit, so the re-GET this panel performs ~1 s after the POST
     * carries PRE-EDIT rows, and the new value only appears on the push after
     * that. The panel therefore painted the player's own edit away within a
     * second and put it back thirteen seconds later, which four separate
     * reports read -- correctly, from where they were sitting -- as "the
     * setting reverted".
     *
     * The fix is not to make the pipeline faster. It is to stop the panel
     * claiming to know something it does not: between the POST and a verdict
     * the authoritative value is UNKNOWN, so the row shows what the player
     * asked for, marked SAVING, and is reconciled when the existing verify
     * ladder returns APPLIED / NOT APPLIED / INCONCLUSIVE. Three states, not
     * two -- the same three words the verdict already uses.
     *
     * Written only by the worker (POST and verify both run there) and read by
     * the render thread through the `sItems` snapshot, so no extra lock. */
    /* A SET, not a slot. It used to be one slot, and a second edit made while
     * the first was still in flight OVERWROTE it: the first row kept whatever
     * badge it happened to be wearing forever (nothing could ever settle it
     * again, because `pend_settle` looked the row up by the ONE key the slot
     * held), and the first edit's verdict was written onto the second row.
     * The user's report -- "if i try to change another setting while one is
     * saving, it does not work great" -- is that, exactly. Each in-flight edit
     * now owns its own entry and is settled BY KEY. */
    AowlOvPend       opt[AOWL_OV_PEND_MAX];
    int32_t          optCountP;    /* live entries in `opt`                    */
    /* THE WRITE DID NOT TAKE.
     *
     * Set by `aowl_ov_settings_set` when the value it POSTed is NOT the value
     * the immediately following re-read brought back -- the one check that
     * could have caught the silent revert that shipped: a 200 with the schema
     * unchanged is byte-for-byte a successful write by status code, and every
     * layer between here and the mod was reporting success. Asserted on the
     * FINISHED STATE (what the row reads now), never on our own request, and
     * phrased as the negative so it can actually fail. Empty = the last write
     * verified. */
    char             writeWhy[200];
    int32_t          itemsImpl;     /* implemented count on the loaded page */
    AowlOvSCat       cats[AOWL_OV_MAX_SCATS];
    int32_t          catCount;

    /* The wrapper scalars every reply carries, kept because the panel is
     * required to show what the backend said rather than a paraphrase. */
    char    control[16];        /* absent | unknown | present            */
    int32_t liveKnownAll;
    /* The other host, in five numbers. These do not decide any row; they are
     * what lets the panel say *why* a row reads unknown, which is the whole
     * difference between "the client says it is not running" and "nobody
     * asked". `clientHost` false means no client host has ever reported to this
     * manager -- and since this panel is drawn inside the game, that is *this*
     * process not having reported yet, not a game that is not running.
     * `clientMore` means the last report did not fit in one poll and the rest
     * are still arriving. */
    int32_t clientHost;
    char    clientSession[20];  /* 1..16 hex; the game process it is about */
    int32_t clientSeq;          /* -1 until one has been seen              */
    int32_t clientRows;
    int32_t clientMore;
    char    summary[192];
    char    side[16];
    char    activeLists[192];   /* comma-joined ids                      */
    char    inEffect[224];      /* the last change reply's own sentence  */
    char    applyNote[224];
    char    applyControl[16];
    int32_t applyRequested, applyDeferred, applyRestart;
    char    applyWhat[96];      /* which gesture produced `results`      */

    /* Bumped by the worker whenever any of the tables above changed. The render
     * thread copies them only when it moves, which is what keeps a frame that
     * changed nothing down to pure drawing. */
    int32_t dataSerial;

    int32_t          backendPort;
    volatile LONG    backendOk;
    volatile LONG    busy;       /* a request is in flight right now      */
    volatile LONG    lastOkTick; /* GetTickCount of the last good answer  */
    volatile LONG    everOk;
    volatile LONG    lastRttMs;   /* how long the last request took, good or bad */
    char             lastError[224];

    HANDLE        worker;
    volatile LONG workerRun;
    AowlOvToggleFn toggleFn;
    void*          toggleUser;

    /* --- the mod-sync feed --- */
    char    syncPath[192];              /* "" until the host asks for it */
    int32_t syncMs;                     /* 0 = off */
    char    syncBody[AOWL_OV_SYNC_MAX];
    /* WHY THE LAST BODY WAS NOT PUBLISHED. A drop used to be an `if` with
     * no else: the serial simply did not move and every consumer could only
     * say "nothing arrived". These three make the refusal speakable -- how
     * many, how big the last refused one was, and whether it was refused for
     * its size or for arriving zlib-deflated. */
    int32_t syncDrops;
    int32_t syncDropLen;
    int32_t syncDropZlib;
    int32_t syncLen;
    int32_t syncSerial;                 /* bumped on every successful fetch */
    int32_t syncTaken;                  /* the serial the host last read */
    int32_t syncAttempts;               /* bumped every time the worker FIRES a
                                          * request for the current syncPath,
                                          * success or failure -- lets a caller
                                          * tell "the worker has not gotten to
                                          * my path yet" from "it has tried and
                                          * something else is wrong". Never
                                          * reset by `sync_start`: it is a
                                          * monotonic counter, and the caller
                                          * is expected to diff against the
                                          * value it read right after arming. */

    /* --- the one-shot POST slot (host->backend write leg) ---
     * Single-slot, like the GET feed above: `postArm` names one path+body the
     * worker has not sent yet. A second `aowl_ov_post_start` before the first
     * is taken REPLACES it -- the caller is expected to wait for
     * `aowl_ov_post_pending()` to clear (or take the previous result) before
     * arming another, same discipline as the GET slot's single path. */
    char    postPath[192];
    char    postBody[AOWL_OV_POST_BODY];
    /* THE EDIT KICK -- the whole reason a settings write is fast now.
      *
      * MEASURED: `cSbPeriodMs = 5000` in `settingsbridge.nim`. An F12 edit was
      * queued at settingshub and only drained by the reply to the host's NEXT
      * scheduled push, and the rows that push carried had been collected
      * BEFORE the drain, so the new value needed the cycle after that too.
      * Two full 5 s cycles for a value that was known the instant the player
      * let go of the control -- 5-10 s typical, 13.7 s measured worst case.
      *
      * The overlay and the settings bridge are IN THE SAME PROCESS, so the
      * bridge never had to wait to be told. This bit is set by the overlay
      * worker the moment it POSTs an edit and taken by the host tick, which
      * collects and publishes immediately instead of at its next cycle. It is
      * a one-way notification -- nothing waits on it, nothing blocks on it,
      * and the overlay worker is not held for a moment by it, so the fact #210
      * circular wait cannot come back through this path. */
    volatile LONG editKick;              /* an F12 edit was just POSTed        */
    volatile LONG postArm;              /* 1 = queued, not yet sent           */
    volatile LONG postInFlight;         /* 1 = sent, waiting on the response  */
    char    postResp[AOWL_OV_SYNC_MAX];
    int32_t postRespLen;
    int32_t postOk;                     /* outcome of the last completed POST */
    int32_t postSerial;                 /* bumped when a response lands       */
    int32_t postTaken;                  /* the serial the host last read      */

    /* --- frame scratch and UI state, render thread only --- */
    AowlOvVert vtx[AOWL_OV_MAX_VERTS];
    int32_t    vtxCount;
    int32_t    frames;

    /* --- the textured-quad batching, render thread only --- *
     *
     * The overlay was ONE draw call with the font SRV bound, which is why it
     * could not draw artwork: every pixel it emitted sampled the same
     * texture. Textured quads need a different SRV per tile and a different
     * pixel shader, so the frame becomes a SEQUENCE of spans over the SAME
     * vertex buffer -- still one buffer, still one upload, still no
     * allocation. A frame with no quads produces exactly one span and issues
     * exactly the one `Draw` it always did.
     *
     * `spanN == 0` therefore means "nothing special happened", and the draw
     * path treats it identically to the old code. That is deliberate: the
     * F3/panel/ESP paths must not change behaviour at all. */
    AowlOvSpan spans[AOWL_OV_MAX_SPANS];
    int32_t    spanN;

    /* The GPU-side texture cache. Mirrors the host region's CPU table slot
     * for slot; `gen` is what detects a redefined or recycled key, because a
     * key alone would let stale pixels render under a fresh name. */
    AowlOvTexEntry texc[AOWL_OV_TEX_MAX];
    int64_t    texUploads;      /* SRVs actually created, ever               */
    int64_t    texMisses;       /* quads dropped for want of a resident tile */

    /* The snapshot the frame is drawn from. Taken under the lock only when
     * `dataSerial` moved, and living here rather than on the stack because
     * Present's stack is the game's and 60 KB of locals in a hooked function is
     * how an overlay overflows a thread with a small reserve. */
    int32_t      snapSerial;
    AowlOvMod    sMods[AOWL_OV_MAX_MODS];
    int32_t      sModCount;
    AowlOvList   sLists[AOWL_OV_MAX_LISTS];
    int32_t      sListCount;
    AowlOvEntry  sEntries[AOWL_OV_MAX_ENTRIES];
    int32_t      sEntryCount;
    AowlOvIssue  sIssues[AOWL_OV_MAX_ISSUES];
    int32_t      sIssueCount;
    AowlOvResult sResults[AOWL_OV_MAX_RESULTS];
    int32_t      sResultCount;
    char         sControl[16], sSide[16], sApplyControl[16];
    char         sSummary[192], sActiveLists[192], sInEffect[224];
    char         sApplyNote[224], sApplyWhat[96], sLastError[224];
    int32_t      sApplyRequested, sApplyDeferred, sApplyRestart, sLiveKnownAll;
    int32_t      sClientHost, sClientSeq, sClientRows, sClientMore;
    char         sClientSession[20];

    /* The settings-mode snapshot, same discipline as the tables above. */
    AowlOvSPage  sPages[AOWL_OV_MAX_SPAGES];
    int32_t      sPageCount;
    AowlOvSItem  sItems[AOWL_OV_MAX_SITEMS];
    AowlOvSCat   sCats[AOWL_OV_MAX_SCATS];
    int32_t      sCatCount;
    char         sItemsWhy[192];
    char         sWriteWhy[200];
    char         sIdxWhy[192];
    int32_t      sItemCount;
    char         sItemsPage[80];
    int32_t      sItemsErr, sItemsImpl;

    int32_t view;
    int32_t filter;
    int32_t scale;         /* 1, 2 or 3 -- see aowl_ov_scale */

    /* --- settings mode, render side --- */
    int32_t settings;          /* 0 = mod manager, 1 = the settings screen */
    int32_t selPage, topPage;  /* the nav cursor and its scroll             */
    /* Wheel notches handed to the settings view for it to route -- the nav
     * column's geometry lives there, so the decision does too. Consumed and
     * zeroed by `aowl_ov_view_settings` every frame it runs. */
    int32_t navWheel;
    /* THE NAV IS FREE-SCROLLED RIGHT NOW.
     *
     * Without this the auto-follow clamp ("keep the cursor on screen") snapped
     * `topPage` back the same frame the wheel moved it, so the nav could not be
     * scrolled away from the selection at all -- the wheel appeared to do
     * nothing. Set by a wheel/PgUp scroll of the nav, cleared the moment the
     * SELECTION moves, which is when following it is what a person expects
     * again. `navSelSeen` is how the clearing is detected. */
    int32_t navFree, navSelSeen;
    /* WHICH OF THE TWO LISTS THE KEYBOARD IS DRIVING: 0 = the control list,
     * 1 = the nav column. TAB toggles it.
     *
     * Before this the arrow keys ALWAYS drove the control list and the nav
     * could only be walked with , . [ ] -- four keys nobody guesses, for the
     * half of the screen a person looks at first. TAB in settings mode used to
     * be a DUPLICATE of ] (next page), so nothing unique is taken: [ and ]
     * still walk the pages, and TAB in the MOD MANAGER still switches view,
     * which is a different handler entirely and is not touched.
     *
     * It gates the arrows BOTH ways, and that is the property the test asserts:
     * the unfocused side must be INERT, or TAB has changed nothing a person
     * can feel. */
    int32_t navFocus;
    /* THE CONTROL LIST IS FREE-SCROLLED RIGHT NOW -- the same shape as
     * `navFree`, and it exists for the same reason.
     *
     * The wheel over the control list used to move the SELECTION by three rows
     * and let the follow-clamp below decide whether the view moved at all. With
     * the cursor anywhere but the last visible row, the first notches moved
     * nothing a person could see: the nav free-scrolled, the settings list did
     * not, and that asymmetry is the whole of "my scroll only works for the
     * pages scroll". The wheel now scrolls the VIEW on both sides, which is
     * what every list on this platform does. Cleared the moment the selection
     * moves, so the keyboard still drags the view along behind it. */
    int32_t itemFree, itemSelSeen;
    /* The second-level nav. `selCat` is an index into `sCats` and -1 means
     * "the whole page", which is what a page with fewer than two categories
     * always shows. It is reset whenever the loaded page changes, because a
     * category index means nothing across pages. */
    int32_t selCat;
    /* The bounds the LAST frame actually drew. The keyboard handler runs on the
     * same thread as the draw and must move the cursor inside the same range
     * the player can see -- two independent computations of "which rows are on
     * screen" is exactly how a cursor ends up selecting a row that is not
     * there. Written by the draw, read by the key handler. */
    int32_t viewLo, viewHi;
    int32_t selItem, topItem;  /* the control cursor and its scroll         */
    char    curPage[80];       /* the page id the render thread wants loaded */
    int32_t curPageIsMod;
    int32_t editItem;          /* the row being text/keybind-edited, or -1   */
    char    editBuf[64];       /* the in-progress edit text                  */
    int32_t capturing;         /* a keybind row is waiting for the next key  */
    int32_t dragItem;          /* the slider being dragged, or -1            */
    float   dragVal;           /* its live value while the button is held    */

    /* --- THE COALESCED WRITE SLOT ---------------------------------------
     *
     * ONE pending write, flushed after a quiet period. Not an optimisation:
     * `aowl_ov_settings_set` POSTs the key AND THEN RE-GETS THE WHOLE PAGE, so
     * one write to `aowl.tarkov` is a 283,798-byte download and a full re-sort
     * and re-build of the nav tree. A slider dragged at 60 Hz, or `-` held down
     * at the keyboard`s ~30 Hz repeat, was one of those per frame. The command
     * queue is AOWL_OV_MAX_CMDS deep and DROPS silently past it, so the same
     * gesture also lost writes at the far end.
     *
     * The slot holds page+key+value. A second edit to the SAME key replaces it
     * -- that is the coalescing. A second edit to a DIFFERENT key FLUSHES the
     * held one first, so two settings can never be collapsed into one and no
     * edit is ever silently dropped for being superseded by an unrelated one.
     *
     * The body stays `{"key":...,"value":...}` for exactly one key, ~40 bytes,
     * whatever was coalesced into it -- so this scheme can never produce the
     * large or chunked body that fact #135 says is answered 200 with the schema
     * UNCHANGED. Coalescing here shrinks the number of writes, never grows one.
     *
     * `writeCount` is monotonic and exists for the harness: "a drag of N frames
     * emits fewer than N writes" is counted here AND independently at the
     * backend, and the two have to agree. */
    char    pendPage[80];
    char    pendKey[80];
    char    pendVal[64];
    DWORD   pendAt;            /* tick of the last edit into the slot        */
    int32_t pendArm;           /* 1 = something is held, not yet sent        */
    int32_t writeCount;        /* writes actually handed to the queue        */

    /* Rows the last page load DROPPED for being `implemented:false`, and the
     * flag that decides whether they are dropped at all. Default OFF: a beta
     * tester must not see a control that does nothing, a developer needs to.
     * Filtering happens at PARSE time (`aowl_ov_read_items`), not in the draw,
     * so the group ranges, the nav counts and the keyboard bounds are all
     * computed over the rows that are actually on screen and cannot disagree
     * with them. */
    int32_t showUnimpl;
    int32_t hiddenCount;       /* worker side */
    int32_t sHiddenCount;      /* snapshot    */

    /* --- the search box (permanent, top of the right pane) ---
     *
     * `search` is the live term. The FILTER IS CACHED: `filt` holds the item
     * indices that match and is recomputed only when `filtStamp` -- a hash of
     * the term, the loaded page and the row count -- moves. Re-filtering 802
     * rows every frame is exactly the per-frame cost this panel's geometry
     * cache exists to avoid, and it would defeat that cache as well, since a
     * frame that rebuilds nothing must not do 802 string compares to find out.
     * `filtCount` is what the header prints, so the count on screen and the
     * rows on screen come from the same pass and cannot disagree. */
    char     search[48];
    int32_t  searchFocus;      /* the box owns the keyboard                  */

    /* --- WHICH NAV NODES ARE OPEN ---
     *
     * One flag per node of the LOADED page, plus one per page. Indices, not
     * paths, because they are only meaningful while a page is loaded and are
     * cleared the moment `sItemsPage` changes -- a stale index would expand
     * whatever now happens to sit there, which is worse than collapsing.
     *
     * A node also counts as open when it is an ANCESTOR OF THE SELECTION, so
     * the branch you are in is never hidden from you and a fresh page opens
     * showing where you are rather than showing nothing. That rule is applied
     * in `aowl_ov_nav_open`, never by writing these flags, so the two can
     * never disagree about the same node. */
    int32_t  navOpen[AOWL_OV_MAX_SCATS];
    int32_t  pageOpen[AOWL_OV_MAX_SPAGES];
    char     navOpenFor[80];   /* the page `navOpen` belongs to */
    int32_t  filt[AOWL_OV_MAX_SITEMS];
    int32_t  filtCount;
    uint32_t filtStamp;        /* what `filt` was computed for; 0 = nothing  */

    /* --- the window: moved, resized, maximised, and made more or less solid ---
     *
     * All four in PANEL UNITS (post-`scale`), which is what every rectangle in
     * this file is in. Zero width means "never placed" and the defaults are
     * taken on the first frame. `panAlpha` is the background alpha 0..255; 255
     * is the solid background the player asked for and 232 is what this panel
     * always had. Persisted -- see `aowl_ov_prefs_save`. */
    float   panX, panY, panW, panH;
    int32_t panMax;            /* maximised: the whole client area           */
    int32_t panAlpha;
    float   preX, preY, preW, preH;  /* the geometry to restore un-maximising */
    int32_t dragWin;           /* the title bar is held                      */
    int32_t dragGrip;          /* the resize grip is held                    */
    float   dragDX, dragDY;    /* cursor-to-corner at grab, in panel units   */
    volatile LONG prefsDirty;  /* geometry changed; the WORKER writes it out */
    int32_t prefsSaveFailed;   /* the file could not be opened; said once      */
    char    prefsPath[300];

    /* --- THE PANEL'S OWN PREFERENCES ------------------------------------
     *
     * Everything here is a thing a person can plausibly want different about
     * the settings panel itself, and every one of them is reachable from the
     * synthetic "Settings Panel" page (`aowl_ov_panel_schema`) rather than
     * only from a key nobody was told about. They persist in the same file the
     * geometry does, as `key=value` lines AFTER the legacy first line -- so an
     * old file still loads and a new file still loads on an old build.
     *
     * `showFooter` hides the legend strip; `savePos` stops the panel writing
     * its geometry back, for somebody who wants it to open in the same place
     * every time; `navW` is the nav column width in panel units; `animate`
     * turns the hint's fade into a cut. `themeName` is the SELECTED theme by
     * NAME, not by index -- an index would silently point at a different theme
     * the moment a user drops another file into the themes folder. */
    int32_t showFooter;        /* draw the legend/footer strip               */
    int32_t savePos;           /* persist geometry as it is dragged          */
    int32_t navW;              /* nav column width, panel units              */
    int32_t animate;           /* fades rather than cuts                     */
    /* 0 = follow the back buffer (what it always did), 1..3 = pinned. The
     * automatic rule is right for most screens and wrong for exactly the
     * person who says so, which is what this is for. */
    int32_t scalePref;
    char    themeName[32];
    volatile LONG themeDirty;  /* the render thread asked for a theme re-pick */

    /* --- the launch hint ("Press F12 for Mod Settings") ---
     *
     * A toast, drawn by this same Present hook, so it needs no detour of its
     * own, no managed object and no allocation at all: the two strings are
     * literals and the only per-frame work is one compare and, while it is up,
     * a dozen quads.
     *
     * `hintState`: 0 not armed, 1 counting down, 2 done (never shown again this
     * launch). `hintAt` is the tick the countdown started. */
    int32_t hintState;
    int32_t hintEnabled;       /* the setting, AS ACTUALLY READ               */
    int32_t hintFetched;       /* the backend has been asked, once            */
    char    hintWhy[192];      /* the value as read, in words, for the log    */
    DWORD   hintAt;
    int32_t hintShownFrames;   /* frames the toast was actually drawn on      */
    DWORD   hintGoneAt;        /* the tick it stopped being drawn             */

    /* --- the geometry cache ---
     *
     * A signature of everything that changes what is on screen. When it has not
     * moved and no input is waiting, the frame reuses the vertices it already
     * has and does not touch the buffer at all -- see `aowl_ov_build`. */
    uint32_t drawSig;
    UINT     sigBbW, sigBbH;   /* the back buffer the cache was built against */
    int32_t  needUpload;   /* the vertex buffer does not match `vtx` yet */
    int32_t  builds;       /* frames that actually rebuilt; for the tests */

    /* Figures that are *displayed* and would otherwise change every frame, held
     * still for half a second at a time. Without this the frame cost printed on
     * the title bar would invalidate the cache that makes it low. */
    DWORD    dispTick;
    int32_t  dispAvgNs, dispMaxNs, dispRttMs, dispStaleS;
    int32_t sel[AOWL_VIEW_COUNT];   /* the cursor, per view */
    int32_t top[AOWL_VIEW_COUNT];   /* the first visible row, per view */


    /* --- THE LOGS SCREEN's state -----------------------------------------
     *
     * `logs` is a RING and `logSeq` is the number of lines ever appended, so a
     * line's slot is `seq % AOWL_OV_LOG_MAX` and a stored sequence can always
     * be tested for having been evicted. The filtered index holds SEQUENCES,
     * not slots, for exactly that reason: an index of slots cannot tell "row 7"
     * from "row 7, overwritten since".
     *
     * The worker writes everything above `logWant`; the render thread writes
     * only the filter/cursor half and `logWant`. */
    AowlOvLogLine logs[AOWL_OV_LOG_MAX];
    int32_t  logSeq;            /* lines ever appended                      */
    int32_t  logCount;          /* lines held (<= AOWL_OV_LOG_MAX)          */
    int32_t  logDropped;        /* lines the ring evicted, ever             */
    int32_t  logSerial;         /* bumped on every append; the cache key    */
    char     logFacets[AOWL_OV_LOG_FACETS][AOWL_OV_LOG_FACETLEN];
    int32_t  logFacetN;
    int32_t  logFacetOver;      /* facets that did not fit the table        */
    /* Per source. `logPath` is derived once from this DLL's own directory --
     * the same directory the host writes both logs into. `logWhy` is why a
     * source is showing nothing, IN WORDS, because an empty pane that does not
     * say whether the file is missing, unreadable or merely quiet is the
     * silent-decline failure this project keeps paying for. */
    char     logPath[AOWL_LOG_SRCS][300];
    long long logOff[AOWL_LOG_SRCS];    /* bytes already consumed            */
    int32_t  logOpened[AOWL_LOG_SRCS]; /* the file has been read at least once */
    int32_t  logFail[AOWL_LOG_SRCS];   /* consecutive failures              */
    int32_t  logOff2[AOWL_LOG_SRCS];   /* self-disabled after MAXFAIL       */
    char     logWhy[AOWL_LOG_SRCS][120];
    int32_t  logLines[AOWL_LOG_SRCS];  /* lines taken from this source      */
    /* A line split across two reads. Carried rather than emitted in halves. */
    char     logCarry[AOWL_LOG_SRCS][AOWL_OV_LOG_TEXT];
    int32_t  logCarryN[AOWL_LOG_SRCS];
    volatile LONG logWant;      /* the render thread is drawing the screen  */
    int32_t  logPathsDone;

    /* The filter, and the cursor's half of it. All render thread. */
    int32_t  logSrcFilt;        /* AOWL_LOGSRC_*                            */
    int32_t  logLvlFilt;        /* 0 = all, else AOWL_LOGLVL_* and worse    */
    int32_t  logFacetFilt;      /* AOWL_LOG_FACET_ALL | _SYSTEM | index     */
    char     logSearch[48];
    int32_t  logSearchFocus;    /* ONLY after `/` or a click. Never on open. */
    int32_t  logFollow;         /* pin to the newest line                   */
    int32_t  logFilt[AOWL_OV_LOG_MAX];   /* sequences that pass             */
    int32_t  logFiltN;
    uint32_t logFiltStamp;      /* what `logFilt` was computed for; 0 = none */
    /* --- cost --- */
    LARGE_INTEGER qpcFreq;
    int32_t       drawn;        /* frames actually drawn; render thread only */
    int32_t       openDrawn;    /* ...of them, since the panel was last opened */
    int32_t       wasVisible;   /* the render thread's own edge detector       */
    int32_t       maxVtx;       /* the busiest frame's vertex count, ever */
    int32_t       vtxDropped;   /* vertices the cap refused (a whole quad
                                   counts 6); must stay 0                  */
    volatile LONG lastNs, avgNs, maxNs;
    volatile LONG avgBuildNs;   /* the geometry half, on its own */
} AowlOvState;

/* The synthetic page id for the panel's own settings -- see
 * `aowl_ov_panel_schema`. Declared here because `aowl_ov_rebuild_pages` puts
 * the page in the nav long before the schema that fills it is defined. */
#define AOWL_OV_PANEL_PAGE "aowl.panel"

static AowlOvState g_ov;

/* ---- optional Present/Resize observers (the graphics post-process) --------
 * The full-frame post-process (abi/aowlspt_graphics.h) cannot install its own
 * Present detour when the overlay already has one: the detour engine refuses a
 * second hook on the same dxgi function (error -9). So instead the overlay
 * calls these back, giving the post-process a place to grade the raw frame
 * BEFORE the overlay draws its UI on top, and a place to drop its back-buffer
 * references before a resize. Both are plain C function pointers set from the
 * host; NULL when nothing registered, which is the overlay-only case. Stored as
 * `void*` because that is what crosses the nimony host cleanly. */
static void* g_ov_prePresent = NULL;   /* void (*)(IDXGISwapChain*) */
static void* g_ov_preResize  = NULL;   /* void (*)(IDXGISwapChain*) */
static void aowl_ov_set_pre_present(void* fn) { g_ov_prePresent = fn; }
static void aowl_ov_set_pre_resize(void* fn)  { g_ov_preResize  = fn; }

static void aowl_ov_fail(const char* why) {
    /* One writer wins and the rest are dropped: the first failure is the
     * interesting one, and a later one is usually a consequence of it. */
    if (InterlockedCompareExchange(&g_ov.broken, 1, 0) == 0) {
        strncpy(g_ov.status, why, sizeof(g_ov.status) - 1);
        g_ov.status[sizeof(g_ov.status) - 1] = 0;
    }
}

static void aowl_ov_note(const char* what) {
    if (!g_ov.broken) {
        strncpy(g_ov.status, what, sizeof(g_ov.status) - 1);
        g_ov.status[sizeof(g_ov.status) - 1] = 0;
    }
}

static int32_t aowl_ov_running(void) { return g_ov.started && !g_ov.broken; }
static int32_t aowl_ov_visible(void) { return (int32_t)g_ov.visible; }
static void    aowl_ov_set_visible(int32_t on) {
    InterlockedExchange(&g_ov.visible, on ? 1 : 0);
}
static int32_t aowl_ov_frames(void) { return g_ov.frames; }
static int32_t aowl_ov_frame_ns(void) { return (int32_t)g_ov.avgNs; }
static int32_t aowl_ov_scale(void) { return g_ov.scale > 0 ? g_ov.scale : 1; }
static int32_t aowl_ov_frame_ns_max(void) { return (int32_t)g_ov.maxNs; }
static int32_t aowl_ov_status(char* buf, int32_t cap) {
    if (!buf || cap <= 0) return 0;
    int32_t n = (int32_t)strlen(g_ov.status);
    if (n > cap - 1) n = cap - 1;
    memcpy(buf, g_ov.status, (size_t)n);
    buf[n] = 0;
    return n;
}
static void aowl_ov_on_toggle(AowlOvToggleFn fn, void* user) {
    g_ov.toggleFn = fn;
    g_ov.toggleUser = user;
}

/* `_snprintf` does not always terminate on the Microsoft CRT. Every narrow
 * formatted string in this file goes through here, so that the exception does
 * not have to be remembered at forty call sites.
 *
 * It sits up here, next to `aowl_ov_copy`, rather than down among the text
 * helpers where it was: nine call sites -- the worker's request building, the
 * protected-mod refusal, and the two hook failures -- reached `_snprintf`
 * directly and terminated by hand or by having a format that cannot fill the
 * buffer, and the only thing standing between them and the wrapper was that
 * the wrapper was defined further down the file than the worker. Being safe
 * because the format happens to be short is a property of today's format
 * string, not of the code.
 *
 * `_snwprintf` is still called directly, once per command kind, for the
 * request path: this wrapper is narrow and that path is wide. All five write
 * the same buffer and exactly one of them runs, so they terminate it once,
 * together, on the line after the chain. */
static void aowl_ov_fmt(char* out, int32_t cap, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(out, (size_t)cap - 1, fmt, ap);
    va_end(ap);
    out[cap - 1] = 0;
}

/* ================================================================== *
 * The mod table
 * ================================================================== */

static void aowl_ov_copy(char* dst, int32_t cap, const char* src) {
    int32_t i = 0;
    if (!src) { dst[0] = 0; return; }
    for (; i < cap - 1 && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
}

/* ------------------------------------------------------------------ *
 * THEMES -- and they are DATA, not code.
 *
 * Every colour the panel draws with used to be a `#define` compiled in. They
 * are now sixteen fields of one struct, and the sixteen macros below read that
 * struct -- so every existing draw site is unchanged and none of them had to
 * learn about theming.
 *
 * A theme is a text file: `name=...` and one `key=RRGGBBAA` line per colour.
 * The BUILT-INS ARE THE SAME TEXT, parsed by the same parser at startup, which
 * is the whole point: there is no privileged code path a built-in takes and a
 * user's file does not, so "write your own" cannot silently be a lesser thing.
 * A user theme is a `*.theme` file under %LOCALAPPDATA%\aowlspt\themes and is
 * picked up by NAME -- copy one out, edit it, share the file.
 *
 * There is no fixed theme COUNT. AOWL_OV_MAX_THEMES is a buffer bound on a
 * fixed-size table (this file allocates nothing), not a design limit, and when
 * it is reached the panel SAYS so rather than dropping files silently.
 *
 * Any key a file omits keeps the value it had from the built-in the theme
 * inherits, so a two-line theme that changes only the accent is legal and does
 * not have to restate fifteen colours it does not care about. */
#define AOWL_OV_MAX_THEMES 64

typedef struct AowlOvTheme {
    char     name[32];
    uint32_t bg, edge, titlebg, text, dim, faint, on, off, hot, selbg,
             rowalt, panebg, warn, err, good, accent;
} AowlOvTheme;

static AowlOvTheme g_ovTheme;                          /* the live palette   */
static AowlOvTheme g_ovThemes[AOWL_OV_MAX_THEMES];
static int32_t     g_ovThemeCount = 0;
static int32_t     g_ovThemeOver  = 0;   /* files that did not fit the table */

#define AOWL_OV_BG        (g_ovTheme.bg)
#define AOWL_OV_EDGE      (g_ovTheme.edge)
#define AOWL_OV_TITLEBG   (g_ovTheme.titlebg)
#define AOWL_OV_TEXT      (g_ovTheme.text)
#define AOWL_OV_DIM       (g_ovTheme.dim)
#define AOWL_OV_FAINT     (g_ovTheme.faint)
#define AOWL_OV_ON        (g_ovTheme.on)
#define AOWL_OV_OFF       (g_ovTheme.off)
#define AOWL_OV_HOT       (g_ovTheme.hot)
#define AOWL_OV_SELBG     (g_ovTheme.selbg)
#define AOWL_OV_ROWALT    (g_ovTheme.rowalt)
#define AOWL_OV_PANEBG    (g_ovTheme.panebg)
#define AOWL_OV_WARN      (g_ovTheme.warn)
#define AOWL_OV_ERR       (g_ovTheme.err)
#define AOWL_OV_GOOD      (g_ovTheme.good)
#define AOWL_OV_ACCENT    (g_ovTheme.accent)

/* The shipped themes, in the file format, byte for byte what a user writes.
 * "Dark" is the palette this panel has always had, unchanged, so an install
 * that never touches the control sees exactly what it saw before. */
static const char* const AOWL_OV_BUILTIN_THEMES[] = {
"name=Dark\n"
"bg=0E1014E8\nedge=78A0C8FF\ntitlebg=1C222CFF\ntext=E2E6ECFF\ndim=828C98FF\n"
"faint=5C6470FF\non=46965AFF\noff=783C3CFF\nhot=506E96FF\nselbg=263A54FF\n"
"rowalt=161A20C8\npanebg=12151BFF\nwarn=E2AA50FF\nerr=E46E64FF\n"
"good=78C88CFF\naccent=96BEEBFF\n",
/* Light: the same roles, inverted ground. Text on background is #22262C on
 * #EEF1F5 -- a luminance contrast well past 7:1 -- and every dim/faint tone
 * was darkened rather than merely flipped, so "faint" stays readable instead
 * of becoming the pale-grey-on-white that light themes usually ship. */
"name=Light\n"
"bg=EEF1F5F0\nedge=5C7894FF\ntitlebg=DCE2EAFF\ntext=22262CFF\ndim=4A5462FF\n"
"faint=6A7484FF\non=2E7844FF\noff=A03C3CFF\nhot=B4C8E0FF\nselbg=C2D4EAFF\n"
"rowalt=E2E7EEC8\npanebg=E4E8EFFF\nwarn=8A5E00FF\nerr=A82820FF\n"
"good=1E6E38FF\naccent=1C4E86FF\n",
/* High contrast: for a player who cannot read the dim tones at all. Nothing
 * is dimmed below #B0B0B0 and the accent is pure. */
"name=High Contrast\n"
"bg=000000FF\nedge=FFFFFFFF\ntitlebg=101010FF\ntext=FFFFFFFF\ndim=D0D0D0FF\n"
"faint=B0B0B0FF\non=00C050FF\noff=E03030FF\nhot=004080FF\nselbg=0050A0FF\n"
"rowalt=1C1C1CFF\npanebg=0A0A0AFF\nwarn=FFC000FF\nerr=FF5040FF\n"
"good=40E080FF\naccent=60D0FFFF\n",
/* Amber: the terminal look, one hue, for somebody who wants the panel to stop
 * competing with the game's own blues. */
"name=Amber\n"
"bg=140F08F0\nedge=C8912CFF\ntitlebg=241A0CFF\ntext=F0D8A8FF\ndim=A88A50FF\n"
"faint=7A6238FF\non=8AA030FF\noff=A0502CFF\nhot=6E5220FF\nselbg=4A3410FF\n"
"rowalt=1E1710C8\npanebg=181208FF\nwarn=E8B040FF\nerr=E07048FF\n"
"good=A8C048FF\naccent=FFCC66FF\n"
};

static int32_t aowl_ov_hexnib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* `RRGGBBAA` or `RRGGBB` (alpha defaults to opaque), with or without a leading
 * `#`. Returns 0 and leaves `*out` alone on anything else -- a typo'd colour
 * must not become a black rectangle the user cannot explain. */
static int32_t aowl_ov_parse_hex(const char* s, uint32_t* out) {
    uint32_t v[4] = { 0, 0, 0, 255 };
    int32_t i, n = 0;
    if (*s == '#') s++;
    while (s[n] && s[n] > ' ') n++;
    if (n != 6 && n != 8) return 0;
    for (i = 0; i < n; i += 2) {
        int32_t a = aowl_ov_hexnib(s[i]), b = aowl_ov_hexnib(s[i + 1]);
        if (a < 0 || b < 0) return 0;
        v[i / 2] = (uint32_t)(a * 16 + b);
    }
    *out = AOWL_RGBA(v[0], v[1], v[2], v[3]);
    return 1;
}

/* One `key=value` line into `T`. Unknown keys are IGNORED rather than fatal:
 * a theme written for a later build that grows a colour must still load here,
 * and a theme written here must still load there. */
static void aowl_ov_theme_kv(AowlOvTheme* T, const char* k, const char* v) {
    struct { const char* k; size_t off; } map[] = {
        { "bg", offsetof(AowlOvTheme, bg) },
        { "edge", offsetof(AowlOvTheme, edge) },
        { "titlebg", offsetof(AowlOvTheme, titlebg) },
        { "text", offsetof(AowlOvTheme, text) },
        { "dim", offsetof(AowlOvTheme, dim) },
        { "faint", offsetof(AowlOvTheme, faint) },
        { "on", offsetof(AowlOvTheme, on) },
        { "off", offsetof(AowlOvTheme, off) },
        { "hot", offsetof(AowlOvTheme, hot) },
        { "selbg", offsetof(AowlOvTheme, selbg) },
        { "rowalt", offsetof(AowlOvTheme, rowalt) },
        { "panebg", offsetof(AowlOvTheme, panebg) },
        { "warn", offsetof(AowlOvTheme, warn) },
        { "err", offsetof(AowlOvTheme, err) },
        { "good", offsetof(AowlOvTheme, good) },
        { "accent", offsetof(AowlOvTheme, accent) }
    };
    int32_t i;
    if (!strcmp(k, "name")) {
        int32_t n = 0;
        while (v[n] && v[n] >= ' ' && n < (int32_t)sizeof(T->name) - 1) {
            T->name[n] = v[n]; n++;
        }
        while (n > 0 && T->name[n - 1] == ' ') n--;
        T->name[n] = 0;
        return;
    }
    for (i = 0; i < (int32_t)(sizeof(map) / sizeof(map[0])); i++)
        if (!strcmp(k, map[i].k)) {
            uint32_t c;
            if (aowl_ov_parse_hex(v, &c))
                *(uint32_t*)((char*)T + map[i].off) = c;
            return;
        }
}

/* A whole theme body into `T`, which arrives pre-seeded with whatever it
 * inherits. `#` and `;` start a comment; blank lines are fine. */
static void aowl_ov_theme_parse(AowlOvTheme* T, const char* body) {
    char line[160];
    int32_t n = 0;
    const char* p = body;
    for (;; p++) {
        if (*p && *p != '\n' && *p != '\r') {
            if (n < (int32_t)sizeof(line) - 1) line[n++] = *p;
            continue;
        }
        line[n] = 0;
        if (n > 0 && line[0] != '#' && line[0] != ';') {
            char* eq = strchr(line, '=');
            if (eq) {
                char key[32];
                int32_t k = 0, i = 0;
                while (line[i] == ' ' || line[i] == '\t') i++;
                while (&line[i] < eq && k < (int32_t)sizeof(key) - 1 &&
                       line[i] > ' ') key[k++] = line[i++];
                key[k] = 0;
                { char* val = eq + 1;
                  while (*val == ' ' || *val == '\t') val++;
                  aowl_ov_theme_kv(T, key, val); }
            }
        }
        n = 0;
        if (!*p) break;
    }
}

static int32_t aowl_ov_theme_find(const char* name) {
    int32_t i;
    for (i = 0; i < g_ovThemeCount; i++)
        if (!_stricmp(g_ovThemes[i].name, name)) return i;
    return -1;
}

/* Make `name` the live palette. A name that is not there does NOT fall back
 * silently to something arbitrary -- it falls back to theme 0, which is the
 * palette this panel has always had, and says so in the status line. */
static void aowl_ov_theme_apply(const char* name) {
    int32_t i = aowl_ov_theme_find(name);
    if (i < 0 && g_ovThemeCount > 0) i = 0;
    if (i < 0) return;
    g_ovTheme = g_ovThemes[i];
    aowl_ov_copy(g_ov.themeName, (int32_t)sizeof(g_ov.themeName),
                 g_ovThemes[i].name);
}

/* Built-ins first, then every `*.theme` file in the themes folder. A user file
 * whose `name` matches a built-in REPLACES it -- that is how somebody adjusts
 * the shipped Dark rather than having to invent a new name for it. */
static void aowl_ov_themes_load(void) {
    int32_t i;
    char dir[300], pat[320], path[340];
    WIN32_FIND_DATAA fd;
    HANDLE h;
    DWORD n;
    g_ovThemeCount = 0; g_ovThemeOver = 0;
    for (i = 0; i < (int32_t)(sizeof(AOWL_OV_BUILTIN_THEMES) /
                              sizeof(AOWL_OV_BUILTIN_THEMES[0])); i++) {
        AowlOvTheme* T = &g_ovThemes[g_ovThemeCount];
        memset(T, 0, sizeof(*T));
        /* A built-in inherits from the FIRST built-in, so a shipped theme that
         * omits a key is as legal as a user one that does. */
        if (g_ovThemeCount > 0) *T = g_ovThemes[0];
        T->name[0] = 0;
        aowl_ov_theme_parse(T, AOWL_OV_BUILTIN_THEMES[i]);
        if (T->name[0]) g_ovThemeCount++;
    }
    /* The live palette exists from here on, whatever happens with the files. */
    if (g_ovThemeCount > 0) g_ovTheme = g_ovThemes[0];

    n = GetEnvironmentVariableA("LOCALAPPDATA", dir, (DWORD)sizeof(dir));
    if (n == 0 || n >= sizeof(dir) - 24) return;
    _snprintf(path, sizeof(path) - 1, "%s\\aowlspt\\themes", dir);
    path[sizeof(path) - 1] = 0;
    CreateDirectoryA(path, NULL);
    _snprintf(pat, sizeof(pat) - 1, "%s\\*.theme", path);
    pat[sizeof(pat) - 1] = 0;
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return;
    do {
        FILE* f;
        char body[4096];
        size_t got;
        AowlOvTheme T;
        int32_t at;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
        if (g_ovThemeCount >= AOWL_OV_MAX_THEMES) { g_ovThemeOver++; continue; }
        _snprintf(path, sizeof(path) - 1, "%s\\aowlspt\\themes\\%s", dir,
                  fd.cFileName);
        path[sizeof(path) - 1] = 0;
        f = fopen(path, "rb");
        if (!f) continue;
        got = fread(body, 1, sizeof(body) - 1, f);
        fclose(f);
        body[got] = 0;
        T = g_ovThemes[0];        /* inherit the shipped Dark, then override */
        T.name[0] = 0;
        aowl_ov_theme_parse(&T, body);
        if (!T.name[0]) {
            /* No `name=` line: the FILENAME is the name, minus `.theme`. A
             * theme with no name at all would be unselectable, which is a
             * theme that silently does not exist. */
            int32_t k = 0;
            while (fd.cFileName[k] && k < (int32_t)sizeof(T.name) - 1 &&
                   fd.cFileName[k] != '.') { T.name[k] = fd.cFileName[k]; k++; }
            T.name[k] = 0;
        }
        if (!T.name[0]) continue;
        at = aowl_ov_theme_find(T.name);
        if (at >= 0) g_ovThemes[at] = T;
        else g_ovThemes[g_ovThemeCount++] = T;
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}

/* Finds by guid, or appends. Returns NULL when the table is full — a full
 * table drops the newest rather than growing on the render thread's behalf. */
static AowlOvMod* aowl_ov_row(const char* guid) {
    for (int32_t i = 0; i < g_ov.modCount; i++)
        if (strcmp(g_ov.mods[i].guid, guid) == 0) return &g_ov.mods[i];
    if (g_ov.modCount >= AOWL_OV_MAX_MODS) return NULL;
    AowlOvMod* m = &g_ov.mods[g_ov.modCount++];
    memset(m, 0, sizeof(*m));
    aowl_ov_copy(m->guid, (int32_t)sizeof(m->guid), guid);
    m->enabled = 1;
    m->order = -1;
    return m;
}

/* Called by the host once per mod it has loaded **or just unloaded**. This is
 * the read-only fallback: if the backend is unreachable the panel still lists
 * what is actually running in this process, which is the information a player
 * most wants and the one source that cannot be wrong.
 *
 * `enabled` is this process's own answer about the library: 1 when the host is
 * holding it, 0 when it is not. The host calls it in both directions -- once
 * per live mod at start-up, and again with 0 the moment `unloadByGuid`
 * succeeds, because a row marked stopped is more use than a row that vanished.
 * So `loaded` follows it rather than being pinned to 1. Pinning it was a bug
 * with a long half-life: an unload pushed a row that said, for the rest of the
 * session, that the mod it had just removed was running. */
static void aowl_ov_set_mod(const char* guid, const char* name,
                            const char* version, int32_t enabled) {
    if (!guid || !guid[0]) return;
    EnterCriticalSection(&g_ov.cs);
    AowlOvMod* m = aowl_ov_row(guid);
    if (m) {
        if (name && name[0]) aowl_ov_copy(m->name, (int32_t)sizeof(m->name), name);
        if (version && version[0])
            aowl_ov_copy(m->version, (int32_t)sizeof(m->version), version);
        m->enabled = enabled ? 1 : 0;
        m->loaded = enabled ? 1 : 0;
        m->hostPushed = 1;
        if (!m->backendRow) {
            /* A sentence, because every other row has one and a blank detail
             * pane on a row that is demonstrably running reads as a bug. It is
             * also the literal truth and the only claim this side can make
             * without asking anybody: whether the process is holding the
             * library. */
            aowl_ov_copy(m->verdict, (int32_t)sizeof(m->verdict),
                         enabled ? "loaded" : "unloaded");
            aowl_ov_copy(m->reason, (int32_t)sizeof(m->reason),
                         enabled
                           ? "loaded in this process; the client host said so"
                           : "taken out of this process; the client host said so");
            aowl_ov_copy(m->from, (int32_t)sizeof(m->from), "client host");
        }
    }
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

static void aowl_ov_clear_mods(void) {
    EnterCriticalSection(&g_ov.cs);
    g_ov.modCount = 0;
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

/* ================================================================== *
 * Backend client
 *
 * WinHTTP, resolved by name at runtime rather than imported. Two reasons, and
 * the second is the one that matters: an import would make `winhttp.dll` a
 * load-time dependency of the host DLL, and the host is injected into a process
 * that is mid-startup — a failed import there is a silent load failure with no
 * log line. Resolving by hand means a missing WinHTTP is a printable status
 * string and a read-only panel.
 *
 * Raw sockets were the other option and would have matched `aowlspt_net.h`.
 * WinHTTP wins here only because it means the header needs no extra link
 * library at all, which keeps the change the client host has to make down to
 * one `#include`.
 * ================================================================== */

typedef void* AOWL_HINTERNET;
typedef AOWL_HINTERNET (WINAPI *AowlWhOpen)(LPCWSTR, DWORD, LPCWSTR, LPCWSTR, DWORD);
typedef AOWL_HINTERNET (WINAPI *AowlWhConnect)(AOWL_HINTERNET, LPCWSTR, WORD, DWORD);
typedef AOWL_HINTERNET (WINAPI *AowlWhOpenReq)(AOWL_HINTERNET, LPCWSTR, LPCWSTR,
                                               LPCWSTR, LPCWSTR, LPCWSTR*, DWORD);
typedef BOOL (WINAPI *AowlWhSend)(AOWL_HINTERNET, LPCWSTR, DWORD, LPVOID, DWORD, DWORD, DWORD_PTR);
typedef BOOL (WINAPI *AowlWhRecv)(AOWL_HINTERNET, LPVOID);
typedef BOOL (WINAPI *AowlWhQueryAvail)(AOWL_HINTERNET, LPDWORD);
typedef BOOL (WINAPI *AowlWhRead)(AOWL_HINTERNET, LPVOID, DWORD, LPDWORD);
typedef BOOL (WINAPI *AowlWhClose)(AOWL_HINTERNET);
typedef BOOL (WINAPI *AowlWhTimeouts)(AOWL_HINTERNET, int, int, int, int);
typedef BOOL (WINAPI *AowlWhSetOption)(AOWL_HINTERNET, DWORD, LPVOID, DWORD);

static struct {
    HMODULE          lib;
    AowlWhOpen       open;
    AowlWhConnect    connect;
    AowlWhOpenReq    openReq;
    AowlWhSend       send;
    AowlWhRecv       recv;
    AowlWhQueryAvail avail;
    AowlWhRead       read;
    AowlWhClose      close;
    AowlWhTimeouts   timeouts;
    AowlWhSetOption  setOption;
    int32_t          ok;
} g_wh;

static int32_t aowl_ov_http_init(void) {
    if (g_wh.ok) return 1;
    g_wh.lib = LoadLibraryA("winhttp.dll");
    if (!g_wh.lib) return 0;
    g_wh.open     = (AowlWhOpen)(void*)GetProcAddress(g_wh.lib, "WinHttpOpen");
    g_wh.connect  = (AowlWhConnect)(void*)GetProcAddress(g_wh.lib, "WinHttpConnect");
    g_wh.openReq  = (AowlWhOpenReq)(void*)GetProcAddress(g_wh.lib, "WinHttpOpenRequest");
    g_wh.send     = (AowlWhSend)(void*)GetProcAddress(g_wh.lib, "WinHttpSendRequest");
    g_wh.recv     = (AowlWhRecv)(void*)GetProcAddress(g_wh.lib, "WinHttpReceiveResponse");
    g_wh.avail    = (AowlWhQueryAvail)(void*)GetProcAddress(g_wh.lib, "WinHttpQueryDataAvailable");
    g_wh.read     = (AowlWhRead)(void*)GetProcAddress(g_wh.lib, "WinHttpReadData");
    g_wh.close    = (AowlWhClose)(void*)GetProcAddress(g_wh.lib, "WinHttpCloseHandle");
    g_wh.timeouts = (AowlWhTimeouts)(void*)GetProcAddress(g_wh.lib, "WinHttpSetTimeouts");
    g_wh.setOption = (AowlWhSetOption)(void*)GetProcAddress(g_wh.lib, "WinHttpSetOption");
    g_wh.ok = (g_wh.open && g_wh.connect && g_wh.openReq && g_wh.send &&
               g_wh.recv && g_wh.avail && g_wh.read && g_wh.close) ? 1 : 0;
    return g_wh.ok;
}

/* The session, opened once and kept.
 *
 * It used to be opened and closed per request, which is the obvious shape and
 * the wrong one. `WinHttpOpen` with `WINHTTP_ACCESS_TYPE_DEFAULT_PROXY` runs
 * proxy detection, and on a machine with no proxy configured that is a WPAD
 * lookup -- DNS for `wpad`, then DHCP -- per call. With four routes on a one
 * second timer that is four of them a second, and when the backend is *down*
 * it was enough to keep the worker inside WinHTTP for over a second at a time
 * while a keypress waited in the queue.
 *
 * `WINHTTP_ACCESS_TYPE_NO_PROXY` (1) is the fix and it is also simply correct:
 * the far end is `127.0.0.1`, which no proxy has ever been the route to.
 * Caching the session on top of that means the steady state is one connect and
 * one request per fetch.
 *
 * The handle is owned by the worker thread and touched by nothing else. It is
 * dropped and reopened after a failure, because a session that has gone bad
 * stays bad and a panel that never recovers is worse than one that reconnects. */
static AOWL_HINTERNET g_whSession;

/* Blocking. Worker thread only. Returns bytes written to `out`, or -1. */
static int32_t aowl_ov_http(const wchar_t* verb, const wchar_t* path,
                            const char* body, char* out, int32_t cap) {
    if (!aowl_ov_http_init()) return -1;
    AOWL_HINTERNET s = NULL, c = NULL, r = NULL;
    int32_t total = -1;

    if (g_whSession) s = g_whSession;
    else {
        s = g_wh.open(L"aowlspt-overlay/1.0", 1 /*WINHTTP_ACCESS_TYPE_NO_PROXY*/,
                      NULL, NULL, 0);
        /* One connect attempt rather than the default five.
         *
         * This does *not* fix the thing it looks like it should. A request to a
         * loopback port with nothing listening takes a measured 2,000 ms inside
         * `WinHttpSendRequest`, and it takes 2,000 ms with `CONNECT_RETRIES`
         * at 1, with `CONNECT_TIMEOUT` at 400 or 100, and with
         * `WinHttpSetTimeouts(300, 500, 500, 1200)`. WinHTTP has a floor there
         * that none of its knobs reaches, and the honest conclusion is that a
         * fetch against a dead backend costs two seconds whatever this file
         * does -- which is why the *worker* is arranged so that nothing a
         * player is waiting on ever queues behind one. See the refusal path in
         * `aowl_ov_worker`.
         *
         * It is set anyway, because it is right for the case that is not
         * loopback-refused: a port that silently drops SYNs, where the five
         * retries really are five SYN timeouts stacked up.
         *
         * Optional, like everything else here: an older WinHTTP without
         * `WinHttpSetOption` gets the default and a longer backoff, not a
         * failure. 3 is WINHTTP_OPTION_CONNECT_RETRIES. */
        if (s && g_wh.setOption) {
            DWORD one = 1;
            g_wh.setOption(s, 3, &one, sizeof(one));
        }
    }
    if (!s) goto done;
    /* Short timeouts on every phase. This runs on our own thread, but a stalled
     * backend must not keep the overlay's "backend reachable" light green for
     * thirty seconds — resolve/connect/send/receive, 300/500/500/1200 ms. This
     * line said 500/800/800/1500 for a while, from before the call below was
     * tightened; the call is the authority and the longer note under it says
     * the same thing without numbers to go stale. */
    /* Resolve / connect / send / receive. The far end is `127.0.0.1` and the
     * near end is a thread inside a game, so these are short on purpose: a
     * stalled backend must not keep the panel's "reachable" light green, and
     * four routes each waiting out a generous timeout is how the worker stops
     * answering the keypress a player is waiting on. See the backoff in
     * `aowl_ov_worker` for the other half of that. */
    if (g_wh.timeouts) g_wh.timeouts(s, 300, 500, 500, 1200);

    c = g_wh.connect(s, L"127.0.0.1", (WORD)g_ov.backendPort, 0);
    if (!c) goto done;
    r = g_wh.openReq(c, verb, path, NULL, NULL, NULL, 0);
    if (!r) goto done;

    {
        /* `Accept-Encoding: identity` is not politeness. `aowlspt-backend`
         * zlib-deflates every response body it sends, with no `Content-Encoding`
         * header, because that is what the Tarkov client expects -- see
         * `sendResponse` in `backend/aowlbackend.nim`. This reader would then be
         * handed 439 bytes starting `78 9C` and would find no rows in them, and
         * the panel would silently fall back to read-only.
         *
         * The header asks the backend not to, and this comment used to say that
         * asking was futile: "it is ignored by the backend as it stands today
         * -- that is a change that has to be made there". **The change was
         * made.** `backend/aowlbackend.nim:515-520` sets `req.identity` when
         * `identity` is asked for without `deflate`, and every `sendResponse`
         * on the mod-control routes passes `not req.identity` as its compress
         * flag.
         *
         * So this header is now load-bearing rather than aspirational, and that
         * is worth stating plainly: if that branch is ever narrowed, this feed
         * goes silent with no error anywhere -- the worker drops any body whose
         * first byte is 0x78 and reports it as a status line, which reads like a
         * network problem and is not one. `tests/ovsync` asserts the body comes
         * back uncompressed by name, so the regression has a name too. The check
         * in the worker below still names it in the status line for the case
         * where somebody points this at a backend that does compress. */
        const wchar_t* hdr =
            body ? L"Content-Type: application/json\r\nAccept-Encoding: identity\r\n"
                 : L"Accept-Encoding: identity\r\n";
        DWORD hdrLen = (DWORD)wcslen(hdr);
        DWORD blen = body ? (DWORD)strlen(body) : 0;
        if (!g_wh.send(r, hdr, hdrLen, (LPVOID)body, blen, blen, 0)) goto done;
    }
    if (!g_wh.recv(r, NULL)) goto done;

    total = 0;
    InterlockedExchange(&g_ov.lastTrunc, 0);
    for (;;) {
        DWORD avail = 0;
        if (!g_wh.avail(r, &avail) || avail == 0) break;
        /* Out of room. Recorded, not swallowed: the caller gets a body that is
         * a PREFIX of valid JSON, which every reader below correctly rejects as
         * "not a schema" -- and for two builds that rejection was the only
         * symptom a 283,798-byte page had. `lastTrunc` is what lets the panel
         * say the size instead of guessing at the cause. */
        if (total >= cap - 1) {
            InterlockedExchange(&g_ov.lastTrunc, (LONG)cap);
            break;
        }
        DWORD want = avail;
        if (want > (DWORD)(cap - 1 - total)) want = (DWORD)(cap - 1 - total);
        DWORD got = 0;
        if (!g_wh.read(r, out + total, want, &got) || got == 0) break;
        total += (int32_t)got;
    }
    out[total < 0 ? 0 : total] = 0;

done:
    if (r) g_wh.close(r);
    if (c) g_wh.close(c);
    if (total < 0) {
        /* Drop the session on any failure and open a fresh one next time. A
         * WinHTTP session that has gone bad does not come back, and a panel
         * that stays dead until the game restarts is worse than one that pays
         * for a new handle every four seconds while the backend is away. */
        if (s) g_wh.close(s);
        g_whSession = NULL;
    } else {
        g_whSession = s;
    }
    return total;
}

/* ------------------------------------------------------------------ *
 * A small structural JSON reader.
 *
 * It is not a parser: it builds no tree and allocates nothing. What it does do
 * is walk the document's *structure* correctly -- strings with escapes, nested
 * objects and arrays, members at a known depth -- which is the difference
 * between reading a document and pattern-matching one.
 *
 * The earlier version of this file did pattern-match. It searched the whole
 * body for `"key"` at any depth and took every `{`..`}` pair as a row, which
 * worked exactly as long as every reply was one flat array of flat objects. It
 * is not sound on the routes this panel now needs:
 *
 *   /aowlspt/mods/lists     each list carries a nested `entries` array, so a
 *                           brace-pair scan reads an entry as a list
 *   /aowlspt/mods/apply     `results` is nested inside the wrapper
 *   /aowlspt/mods/toggle    `row` and `apply` are both nested objects, and
 *                           `apply.results[].message` carries a Windows path
 *                           whose backslashes arrive as `\\` escapes -- which a
 *                           scanner that does not understand `\"` walks through
 *
 * So the four primitives below are: skip a value, find a member of *this*
 * object, start an array, step an array. Everything else is written in terms of
 * them, and each one is bounded by `end` on every read.
 *
 * Non-ASCII is not decoded. The font atlas is ASCII 32..126, so a `\uXXXX`
 * escape or a UTF-8 lead byte becomes `?` rather than a garbage glyph -- the
 * registry is text written by mod authors, and a mod whose name has an umlaut
 * in it should show as `?` in one column rather than as a torn line.
 * ------------------------------------------------------------------ */

static const char* aowl_ov_jws(const char* p, const char* e) {
    while (p < e && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
    return p;
}

/* `p` is at the opening quote; returns one past the closing quote. */
static const char* aowl_ov_jstr_end(const char* p, const char* e) {
    p++;
    while (p < e) {
        if (*p == '\\') { p += 2; continue; }
        if (*p == '"') return p + 1;
        p++;
    }
    return e;
}

/* One past the end of the value at `p`, whatever kind it is. */
static const char* aowl_ov_jval_end(const char* p, const char* e) {
    p = aowl_ov_jws(p, e);
    if (p >= e) return e;
    if (*p == '"') return aowl_ov_jstr_end(p, e);
    if (*p == '{' || *p == '[') {
        int32_t depth = 0;
        while (p < e) {
            if (*p == '"') { p = aowl_ov_jstr_end(p, e); continue; }
            if (*p == '{' || *p == '[') { depth++; p++; continue; }
            if (*p == '}' || *p == ']') {
                depth--;
                p++;
                if (depth <= 0) return p;
                continue;
            }
            p++;
        }
        return e;
    }
    while (p < e && *p != ',' && *p != '}' && *p != ']' &&
           *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r') p++;
    return p;
}

/* The value of `key` in the object at `o`, at that object's own depth and
 * nowhere else. NULL when the object does not have it -- which is a real answer
 * and not an error: every field this reader wants is optional, and a reply that
 * omits one leaves whatever was already known alone. */
static const char* aowl_ov_jmem(const char* o, const char* e, const char* key) {
    size_t klen = strlen(key);
    const char* p;
    if (!o) return NULL;
    p = aowl_ov_jws(o, e);
    if (p >= e || *p != '{') return NULL;
    p = aowl_ov_jws(p + 1, e);
    while (p < e && *p == '"') {
        const char* ks = p + 1;
        const char* after = aowl_ov_jstr_end(p, e);
        const char* ke = after - 1;          /* the closing quote */
        p = aowl_ov_jws(after, e);
        if (p < e && *p == ':') p++;
        p = aowl_ov_jws(p, e);
        if ((size_t)(ke - ks) == klen && strncmp(ks, key, klen) == 0) return p;
        p = aowl_ov_jws(aowl_ov_jval_end(p, e), e);
        if (p < e && *p == ',') { p = aowl_ov_jws(p + 1, e); continue; }
        break;
    }
    return NULL;
}

/* The first element of the array at `p`, or NULL for "not an array, or empty". */
static const char* aowl_ov_jarr(const char* p, const char* e) {
    if (!p) return NULL;
    p = aowl_ov_jws(p, e);
    if (p >= e || *p != '[') return NULL;
    p = aowl_ov_jws(p + 1, e);
    if (p >= e || *p == ']') return NULL;
    return p;
}

/* The next element after the one at `p`, or NULL at the end. */
static const char* aowl_ov_jnext(const char* p, const char* e) {
    p = aowl_ov_jws(aowl_ov_jval_end(p, e), e);
    if (p < e && *p == ',') {
        p = aowl_ov_jws(p + 1, e);
        if (p < e && *p != ']') return p;
    }
    return NULL;
}

/* A string value into a fixed buffer, escapes undone, always terminated. */
static void aowl_ov_jtext(const char* v, const char* e, char* out, int32_t cap) {
    int32_t i = 0;
    out[0] = 0;
    if (!v) return;
    v = aowl_ov_jws(v, e);
    if (v >= e || *v != '"') return;
    v++;
    while (v < e && *v != '"' && i < cap - 1) {
        unsigned char c = (unsigned char)*v;
        if (c == '\\') {
            v++;
            if (v >= e) break;
            if (*v == 'n')      { out[i++] = '\n'; v++; }
            else if (*v == 't') { out[i++] = ' ';  v++; }
            else if (*v == 'r' || *v == 'b' || *v == 'f') { v++; }
            else if (*v == 'u') {
                /* Four hex digits, and the only ones this font can draw are the
                 * ASCII range. Everything else is one `?`, deliberately:
                 * decoding it properly would need a UTF-8 encoder and an atlas
                 * that has the glyph, and there is neither. */
                int32_t k = 0, val = 0;
                v++;
                for (; k < 4 && v < e; k++, v++) {
                    char h = *v;
                    int32_t d = (h >= '0' && h <= '9') ? h - '0'
                              : (h >= 'a' && h <= 'f') ? h - 'a' + 10
                              : (h >= 'A' && h <= 'F') ? h - 'A' + 10 : -1;
                    if (d < 0) break;
                    val = val * 16 + d;
                }
                out[i++] = (val >= 32 && val < 127) ? (char)val : '?';
            }
            else { out[i++] = *v; v++; }   /* \" \\ \/ and anything else */
        } else if (c < 32 || c > 126) {
            out[i++] = '?';
            v++;
        } else {
            out[i++] = (char)c;
            v++;
        }
    }
    out[i] = 0;
}

static int32_t aowl_ov_jbool(const char* v, const char* end, int32_t dflt) {
    if (!v) return dflt;
    v = aowl_ov_jws(v, end);
    if (v >= end) return dflt;
    if (*v == 't' || *v == '1') return 1;
    if (*v == 'f' || *v == '0') return 0;
    return dflt;
}

static int32_t aowl_ov_jisnull(const char* v, const char* end) {
    if (!v) return 1;
    v = aowl_ov_jws(v, end);
    return (v < end && *v == 'n') ? 1 : 0;
}

static int32_t aowl_ov_jint(const char* v, const char* end, int32_t dflt) {
    int32_t sign = 1, n = 0, any = 0;
    if (!v) return dflt;
    v = aowl_ov_jws(v, end);
    if (v < end && (*v == '-' || *v == '+')) { if (*v == '-') sign = -1; v++; }
    while (v < end && *v >= '0' && *v <= '9') { n = n * 10 + (*v - '0'); v++; any = 1; }
    return any ? sign * n : dflt;
}

/* An array of strings, joined with ", " into one printable field. Used for
 * `active` and for a list's `inherits`, both of which are only ever read. */
static void aowl_ov_jjoin(const char* v, const char* end, char* out, int32_t cap) {
    int32_t n = 0;
    const char* it;
    char one[96];
    out[0] = 0;
    for (it = aowl_ov_jarr(v, end); it; it = aowl_ov_jnext(it, end)) {
        int32_t i;
        aowl_ov_jtext(it, end, one, (int32_t)sizeof(one));
        if (!one[0]) continue;
        if (n > 0 && n < cap - 3) { out[n++] = ','; out[n++] = ' '; }
        for (i = 0; one[i] && n < cap - 1; i++) out[n++] = one[i];
        out[n] = 0;
    }
    out[n] = 0;
}

/* True when `id` appears as a whole comma-separated token in `joined`. Not a
 * bare `strstr`: `aowl.list.core` is a prefix of nothing in the registry today
 * but would be of `aowl.list.core.extra` tomorrow, and a list that lights up as
 * active because another list's id contains its own is a lie about what is
 * running. */
static int32_t aowl_ov_intoken(const char* joined, const char* id) {
    size_t n = strlen(id);
    const char* q;
    if (!n) return 0;
    for (q = joined; *q; q++) {
        if (strncmp(q, id, n) == 0 &&
            (q == joined || q[-1] == ' ' || q[-1] == ',') &&
            (q[n] == 0 || q[n] == ',')) return 1;
    }
    return 0;
}

/* True when `body` is one whole, balanced JSON value and nothing else.
 *
 * `aowl_ov_http` truncates at its buffer, and a truncated object is the one
 * input this reader is otherwise happy with: `{"mods":[{"guid":"aowl.sa` parses
 * as a row for a mod called `aowl.sa`, which would then appear on the panel and
 * be togglable. So every body is checked for balance before any of it is
 * believed, and a short one is dropped whole. That is the same rule the
 * mod-sync feed already applies for the same reason -- a partial answer must
 * look like no answer, never like a small one. */
static int32_t aowl_ov_jwhole(const char* body, int32_t len) {
    const char* end = body + len;
    const char* p = aowl_ov_jws(body, end);
    if (p >= end || (*p != '{' && *p != '[')) return 0;
    p = aowl_ov_jval_end(p, end);
    /* `aowl_ov_jval_end` returns `end` for an unbalanced value and one past the
     * closing brace for a balanced one, so the two are told apart by whether
     * anything but whitespace is left -- and a body whose last byte *is* the
     * brace lands exactly on `end`. Hence the explicit close check. */
    if (p > body && (p[-1] == '}' || p[-1] == ']')) {
        p = aowl_ov_jws(p, end);
        return p >= end;
    }
    return 0;
}

/* Copies a member's string into `dst` only when the member is there and is not
 * empty. "Absent" and "empty" both have to mean "leave what you had": the panel
 * merges four routes plus whatever the client host pushed in, and a reply that
 * does not mention a field must not blank it. */
static void aowl_ov_jput(const char* o, const char* e, const char* key,
                         char* dst, int32_t cap) {
    char tmp[256];
    const char* v = aowl_ov_jmem(o, e, key);
    if (!v) return;
    aowl_ov_jtext(v, e, tmp, (int32_t)sizeof(tmp));
    if (tmp[0]) aowl_ov_copy(dst, cap, tmp);
}

/* ------------------------------------------------------------------ *
 * One reader per route
 * ------------------------------------------------------------------ */

/* "Is it running", off one manager row -- `/panel`'s rows and the single row a
 * toggle reply carries, which `manager.nim` builds with the same `panelRow`.
 *
 * Two facts arrive together here and the order matters:
 *
 *   `clientLive` and its three companions are present **only** where the
 *   manager holds a record from the game's host. Absence is read as absence:
 *   `clientKnown` is cleared, because a row that had a record and no longer
 *   does is a row the ledger has dropped (a new game process, a guid the
 *   registry stopped naming) and keeping the old answer would be a fact about
 *   a process that is gone.
 *
 *   `live` is the manager's arbitration over both hosts. It may lower a
 *   host-pushed row only when this row carries `clientLive` -- see the note on
 *   `hostPushed`. Without a record it is still the server's inventory talking
 *   about a process it cannot see.
 *
 * Caller holds `g_ov.cs`. */
static void aowl_ov_prefs_save(void);   /* defined with the panel geometry */

static void aowl_ov_read_row_live(const char* it, const char* end,
                                  AowlOvMod* m) {
    const char* cl = aowl_ov_jmem(it, end, "clientLive");
    const char* lv;
    if (cl && !aowl_ov_jisnull(cl, end)) {
        m->clientKnown = 1;
        m->clientLive = aowl_ov_jbool(cl, end, 0);
        m->clientWant = aowl_ov_jbool(aowl_ov_jmem(it, end, "clientWant"), end, 0);
        m->clientOutcome[0] = 0;
        m->clientCode[0] = 0;
        aowl_ov_jput(it, end, "clientOutcome", m->clientOutcome,
                     (int32_t)sizeof(m->clientOutcome));
        /* `clientCode` rides only on skipped/refused/on-restart, so it is
         * legitimately absent on a row that has an outcome. Cleared above
         * rather than left, or a mod that failed once and then loaded would
         * keep printing the slug that no longer applies to it. */
        aowl_ov_jput(it, end, "clientCode", m->clientCode,
                     (int32_t)sizeof(m->clientCode));
    } else {
        m->clientKnown = 0;
        m->clientLive = 0;
        m->clientWant = 0;
        m->clientOutcome[0] = 0;
        m->clientCode[0] = 0;
    }

    lv = aowl_ov_jmem(it, end, "live");
    if (lv && !aowl_ov_jisnull(lv, end)) {
        m->liveKnown = 1;
        if (!m->hostPushed || m->clientKnown)
            m->loaded = aowl_ov_jbool(lv, end, m->loaded);
    }
}

/* GET /aowlspt/mods/panel -- the rows, plus the wrapper scalars.
 * Caller holds `g_ov.cs`. */
static void aowl_ov_read_panel(const char* body, int32_t len) {
    const char* end = body + len;
    if (!aowl_ov_jwhole(body, len)) return;   /* truncated: no answer, not a small one */
    const char* rows;
    const char* it;
    aowl_ov_jput(body, end, "control", g_ov.control, (int32_t)sizeof(g_ov.control));
    aowl_ov_jput(body, end, "side", g_ov.side, (int32_t)sizeof(g_ov.side));
    aowl_ov_jput(body, end, "summary", g_ov.summary, (int32_t)sizeof(g_ov.summary));
    g_ov.liveKnownAll = aowl_ov_jbool(aowl_ov_jmem(body, end, "liveKnown"), end,
                                      g_ov.liveKnownAll);
    /* The other host's own state, which decides nothing on any row and is the
     * only thing that can tell one kind of unknown from another. Defaulted to
     * what is already held, so a manager too old to send them leaves the panel
     * saying what it last knew rather than "no client host" -- which would be a
     * claim, and the wrong one. */
    g_ov.clientHost = aowl_ov_jbool(aowl_ov_jmem(body, end, "clientHost"), end,
                                    g_ov.clientHost);
    aowl_ov_jput(body, end, "clientSession", g_ov.clientSession,
                 (int32_t)sizeof(g_ov.clientSession));
    g_ov.clientSeq = aowl_ov_jint(aowl_ov_jmem(body, end, "clientSeq"), end,
                                  g_ov.clientSeq);
    g_ov.clientRows = aowl_ov_jint(aowl_ov_jmem(body, end, "clientRows"), end,
                                   g_ov.clientRows);
    g_ov.clientMore = aowl_ov_jbool(aowl_ov_jmem(body, end, "clientMore"), end,
                                    g_ov.clientMore);

    rows = aowl_ov_jmem(body, end, "mods");
    for (it = aowl_ov_jarr(rows, end); it; it = aowl_ov_jnext(it, end)) {
        char guid[80];
        AowlOvMod* m;
        const char* g = aowl_ov_jmem(it, end, "guid");
        const char* rs;
        int32_t want;
        if (!g) g = aowl_ov_jmem(it, end, "id");
        aowl_ov_jtext(g, end, guid, (int32_t)sizeof(guid));
        if (!guid[0]) continue;
        m = aowl_ov_row(guid);
        if (!m) continue;
        m->backendRow = 1;

        aowl_ov_jput(it, end, "name", m->name, (int32_t)sizeof(m->name));
        aowl_ov_jput(it, end, "version", m->version, (int32_t)sizeof(m->version));
        aowl_ov_jput(it, end, "verdict", m->verdict, (int32_t)sizeof(m->verdict));
        aowl_ov_jput(it, end, "reason", m->reason, (int32_t)sizeof(m->reason));
        /* `protected` is the manager saying it will refuse to switch this one
         * off, whichever door the request comes through -- `routeDisable`,
         * `routeToggle`, or `applySelection` after somebody hand-edited the
         * selection file. Defaulting to what the row already has, so a reply
         * from an older manager that does not send the field leaves whatever
         * was known rather than quietly unprotecting a row. */
        m->protectedRow = aowl_ov_jbool(aowl_ov_jmem(it, end, "protected"), end,
                                        m->protectedRow);

        want = aowl_ov_jbool(aowl_ov_jmem(it, end, "enabled"), end, m->enabled);
        /* Only the backend's answer clears `pending`. The row shows a `~` from
         * the moment it is asked for until the server confirms the state that
         * was asked for, so a request that silently failed stays visible on the
         * panel rather than looking applied. */
        if (m->pending && want == m->enabled) m->pending = 0;
        m->enabled = want;

        aowl_ov_read_row_live(it, end, m);

        rs = aowl_ov_jmem(it, end, "restart");
        if (rs) m->restart = aowl_ov_jbool(rs, end, m->restart);
    }
}

/* GET /aowlspt/mods/list -- the half of a decision the panel route does not
 * carry: which list decided this mod, and whether *you* decided it.
 *
 * This is the one place the overlay reads two routes for one row, and it is
 * worth saying why rather than asking the manager for a wider panel route.
 * `/list` is the manager's own general answer, already exactly this shape,
 * already flat, and served to every other consumer; `from` and `explicit` on it
 * are the same fields `mods/manager` writes into `/describe` and into every
 * change reply. Widening `/panel` would have meant a second copy of two fields
 * in a route that exists solely for this reader, in a file this work does not
 * own, to save one GET against a loopback socket on a worker thread.
 *
 * Caller holds `g_ov.cs`. */
static void aowl_ov_read_list(const char* body, int32_t len) {
    const char* end = body + len;
    if (!aowl_ov_jwhole(body, len)) return;   /* truncated: no answer, not a small one */
    const char* rows = aowl_ov_jmem(body, end, "mods");
    const char* it;
    for (it = aowl_ov_jarr(rows, end); it; it = aowl_ov_jnext(it, end)) {
        char id[80];
        AowlOvMod* m;
        const char* fv;
        aowl_ov_jtext(aowl_ov_jmem(it, end, "id"), end, id, (int32_t)sizeof(id));
        if (!id[0]) continue;
        m = aowl_ov_row(id);
        if (!m) continue;
        m->backendRow = 1;
        aowl_ov_jput(it, end, "name", m->name, (int32_t)sizeof(m->name));
        aowl_ov_jput(it, end, "verdict", m->verdict, (int32_t)sizeof(m->verdict));
        aowl_ov_jput(it, end, "reason", m->reason, (int32_t)sizeof(m->reason));
        /* `from` is legitimately the empty string for a mod no list mentions,
         * so this one is *not* routed through `aowl_ov_jput`: "" is the answer
         * and has to replace whatever was there. */
        fv = aowl_ov_jmem(it, end, "from");
        if (fv) aowl_ov_jtext(fv, end, m->from, (int32_t)sizeof(m->from));
        m->explicitOv = aowl_ov_jbool(aowl_ov_jmem(it, end, "explicit"), end,
                                      m->explicitOv);
        m->order = aowl_ov_jint(aowl_ov_jmem(it, end, "order"), end, m->order);
    }
}

/* GET /aowlspt/mods/lists -- the named lists, which are active, and what each
 * one contains. Caller holds `g_ov.cs`. */
static void aowl_ov_read_lists(const char* body, int32_t len) {
    const char* end = body + len;
    if (!aowl_ov_jwhole(body, len)) return;   /* truncated: no answer, not a small one */
    const char* ls;
    const char* it;
    aowl_ov_jjoin(aowl_ov_jmem(body, end, "active"), end,
                  g_ov.activeLists, (int32_t)sizeof(g_ov.activeLists));

    g_ov.listCount = 0;
    g_ov.entryCount = 0;
    ls = aowl_ov_jmem(body, end, "lists");
    for (it = aowl_ov_jarr(ls, end); it; it = aowl_ov_jnext(it, end)) {
        AowlOvList* L;
        const char* es;
        const char* ei;
        if (g_ov.listCount >= AOWL_OV_MAX_LISTS) break;
        L = &g_ov.lists[g_ov.listCount];
        memset(L, 0, sizeof(*L));
        aowl_ov_jput(it, end, "id", L->id, (int32_t)sizeof(L->id));
        if (!L->id[0]) continue;
        aowl_ov_jput(it, end, "name", L->name, (int32_t)sizeof(L->name));
        aowl_ov_jput(it, end, "description", L->desc, (int32_t)sizeof(L->desc));
        aowl_ov_jjoin(aowl_ov_jmem(it, end, "inherits"), end,
                      L->inherits, (int32_t)sizeof(L->inherits));
        L->active = aowl_ov_intoken(g_ov.activeLists, L->id);

        es = aowl_ov_jmem(it, end, "entries");
        for (ei = aowl_ov_jarr(es, end); ei; ei = aowl_ov_jnext(ei, end)) {
            AowlOvEntry* E;
            if (g_ov.entryCount >= AOWL_OV_MAX_ENTRIES) break;
            E = &g_ov.entries[g_ov.entryCount];
            memset(E, 0, sizeof(*E));
            E->list = g_ov.listCount;
            aowl_ov_jput(ei, end, "id", E->id, (int32_t)sizeof(E->id));
            if (!E->id[0]) continue;
            E->enabled = aowl_ov_jbool(aowl_ov_jmem(ei, end, "enabled"), end, 1);
            aowl_ov_jput(ei, end, "note", E->note, (int32_t)sizeof(E->note));
            g_ov.entryCount++;
            L->entries++;
        }
        g_ov.listCount++;
    }
}

/* GET /aowlspt/mods/conflicts -- only what is wrong, which is the question
 * asked at two in the morning. Caller holds `g_ov.cs`. */
static void aowl_ov_read_conflicts(const char* body, int32_t len) {
    const char* end = body + len;
    if (!aowl_ov_jwhole(body, len)) return;   /* truncated: no answer, not a small one */
    const char* ex;
    const char* pr;
    const char* it;
    g_ov.issueCount = 0;

    ex = aowl_ov_jmem(body, end, "excluded");
    for (it = aowl_ov_jarr(ex, end); it; it = aowl_ov_jnext(it, end)) {
        AowlOvIssue* s;
        if (g_ov.issueCount >= AOWL_OV_MAX_ISSUES) break;
        s = &g_ov.issues[g_ov.issueCount];
        memset(s, 0, sizeof(*s));
        aowl_ov_jput(it, end, "id", s->id, (int32_t)sizeof(s->id));
        aowl_ov_jput(it, end, "verdict", s->verdict, (int32_t)sizeof(s->verdict));
        aowl_ov_jput(it, end, "reason", s->text, (int32_t)sizeof(s->text));
        if (s->id[0]) g_ov.issueCount++;
    }
    pr = aowl_ov_jmem(body, end, "problems");
    for (it = aowl_ov_jarr(pr, end); it; it = aowl_ov_jnext(it, end)) {
        AowlOvIssue* s;
        if (g_ov.issueCount >= AOWL_OV_MAX_ISSUES) break;
        s = &g_ov.issues[g_ov.issueCount];
        memset(s, 0, sizeof(*s));
        aowl_ov_copy(s->verdict, (int32_t)sizeof(s->verdict), "registry");
        aowl_ov_jtext(it, end, s->text, (int32_t)sizeof(s->text));
        if (s->text[0]) g_ov.issueCount++;
    }
}

/* The `apply` object -- from `/apply` itself, or from the `apply` member of a
 * toggle's reply. `o` points at that object. Caller holds `g_ov.cs`. */
static void aowl_ov_read_apply(const char* o, const char* end, const char* what) {
    const char* rs;
    const char* it;
    aowl_ov_copy(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat), what);
    g_ov.applyRequested = aowl_ov_jint(aowl_ov_jmem(o, end, "requested"), end, 0);
    g_ov.applyDeferred  = aowl_ov_jint(aowl_ov_jmem(o, end, "deferred"), end, 0);
    g_ov.applyRestart   = aowl_ov_jbool(aowl_ov_jmem(o, end, "restartRequired"), end, 0);
    g_ov.applyControl[0] = 0;
    aowl_ov_jput(o, end, "control", g_ov.applyControl, (int32_t)sizeof(g_ov.applyControl));
    g_ov.applyNote[0] = 0;
    aowl_ov_jput(o, end, "note", g_ov.applyNote, (int32_t)sizeof(g_ov.applyNote));

    g_ov.resultCount = 0;
    rs = aowl_ov_jmem(o, end, "results");
    for (it = aowl_ov_jarr(rs, end); it; it = aowl_ov_jnext(it, end)) {
        AowlOvResult* r;
        if (g_ov.resultCount >= AOWL_OV_MAX_RESULTS) break;
        r = &g_ov.results[g_ov.resultCount];
        memset(r, 0, sizeof(*r));
        aowl_ov_jput(it, end, "id", r->id, (int32_t)sizeof(r->id));
        aowl_ov_jput(it, end, "action", r->action, (int32_t)sizeof(r->action));
        aowl_ov_jput(it, end, "outcome", r->outcome, (int32_t)sizeof(r->outcome));
        aowl_ov_jput(it, end, "message", r->message, (int32_t)sizeof(r->message));
        if (r->id[0]) g_ov.resultCount++;
    }
}

/* The answer to a POST or to a change GET. Everything shown from it is the
 * server's own text: `ok`, `error`, `inEffect`, `control`, and the per-mod
 * outcomes. Nothing here is inferred and nothing is reworded. */
static void aowl_ov_read_reply(const char* body, int32_t len, const char* what) {
    const char* end = body + len;
    if (!aowl_ov_jwhole(body, len)) return;
    const char* v;
    const char* d;
    const char* r;
    const char* ap;
    EnterCriticalSection(&g_ov.cs);

    if (!aowl_ov_jbool(aowl_ov_jmem(body, end, "ok"), end, 1)) {
        /* A refusal. The manager's own sentence -- which for a mod its registry
         * does not have runs to a couple of hundred characters and explains
         * exactly that -- is shown rather than summarised. */
        g_ov.resultCount = 0;
        aowl_ov_copy(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat), what);
        g_ov.applyRequested = 0;
        g_ov.applyDeferred = 0;
        g_ov.applyRestart = 0;
        g_ov.applyNote[0] = 0;
        g_ov.inEffect[0] = 0;
        g_ov.lastError[0] = 0;
        aowl_ov_jput(body, end, "error", g_ov.lastError,
                     (int32_t)sizeof(g_ov.lastError));
        LeaveCriticalSection(&g_ov.cs);
        g_ov.dataSerial++;
        return;
    }
    g_ov.lastError[0] = 0;

    aowl_ov_jput(body, end, "control", g_ov.control, (int32_t)sizeof(g_ov.control));
    /* `inEffect` is on enable/disable/clear, and it is the manager saying in
     * its own words whether the change just made is true yet. It is the single
     * most load-bearing sentence on this panel, and it is printed verbatim. */
    v = aowl_ov_jmem(body, end, "inEffect");
    if (v) aowl_ov_jtext(v, end, g_ov.inEffect, (int32_t)sizeof(g_ov.inEffect));

    /* A change reply carries the decision it produced; fold it straight into
     * the row so the panel does not have to wait out a poll to be right. */
    d = aowl_ov_jmem(body, end, "decision");
    if (d) {
        char id[80];
        AowlOvMod* m;
        const char* fv;
        aowl_ov_jtext(aowl_ov_jmem(d, end, "id"), end, id, (int32_t)sizeof(id));
        m = id[0] ? aowl_ov_row(id) : NULL;
        if (m) {
            aowl_ov_jput(d, end, "verdict", m->verdict, (int32_t)sizeof(m->verdict));
            aowl_ov_jput(d, end, "reason", m->reason, (int32_t)sizeof(m->reason));
            fv = aowl_ov_jmem(d, end, "from");
            if (fv) aowl_ov_jtext(fv, end, m->from, (int32_t)sizeof(m->from));
            m->explicitOv = aowl_ov_jbool(aowl_ov_jmem(d, end, "explicit"), end, 0);
            m->pending = 0;
        }
    }
    /* A toggle reply carries a whole panel row. */
    r = aowl_ov_jmem(body, end, "row");
    if (r) {
        char id[80];
        AowlOvMod* m;
        const char* g = aowl_ov_jmem(r, end, "guid");
        if (!g) g = aowl_ov_jmem(r, end, "id");
        aowl_ov_jtext(g, end, id, (int32_t)sizeof(id));
        m = id[0] ? aowl_ov_row(id) : NULL;
        if (m) {
            m->enabled = aowl_ov_jbool(aowl_ov_jmem(r, end, "enabled"), end, m->enabled);
            m->restart = aowl_ov_jbool(aowl_ov_jmem(r, end, "restart"), end, m->restart);
            aowl_ov_read_row_live(r, end, m);
            aowl_ov_jput(r, end, "verdict", m->verdict, (int32_t)sizeof(m->verdict));
            aowl_ov_jput(r, end, "reason", m->reason, (int32_t)sizeof(m->reason));
            m->pending = 0;
        }
    }

    ap = aowl_ov_jmem(body, end, "apply");
    if (ap) aowl_ov_read_apply(ap, end, what);
    else if (aowl_ov_jmem(body, end, "results")) aowl_ov_read_apply(body, end, what);

    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

/* ------------------------------------------------------------------ *
 * The worker thread
 *
 * Every blocking call in this file happens here and nowhere else. The render
 * thread never touches a socket, never waits on this thread, and never reads a
 * field this thread is halfway through writing -- the tables are copied out
 * under `g_ov.cs` and only when `dataSerial` has moved.
 *
 * It polls four routes rather than one, because a mod manager needs four
 * different answers and the manager already serves each of them:
 *
 *   /panel      1 s    the rows: name, version, enabled, live, restart,
 *                      verdict, reason, plus control/liveKnown/summary
 *   /list       1 s    `from` and `explicit` per row -- who decided this, and
 *                      was it you
 *   /lists      3 s    the named lists, which are active, what each contains
 *   /conflicts  3 s    only what is wrong, before you apply rather than after
 *
 * The two slow ones are also fetched immediately after any command, because a
 * command is exactly the thing that changes them.
 *
 * A route that fails leaves its own table alone. That is not politeness: a
 * panel that empties itself when one GET times out is a panel that tells the
 * player their mods vanished.
 * ------------------------------------------------------------------ */

/* Fills `out` and returns its length, or -1. Sets the reachability light and
 * the status line as a side effect, because every caller wants both and the
 * one thing worse than a wrong answer here is a stale "backend up". */
/* ------------------------------------------------------------------ *
 * Settings schema readers
 *
 * The same structural walker as the mod-control readers above, turned on the
 * two shapes the settings screen fetches: a mod's page is a flat array of
 * control objects, and an SPT page is one object with a `settings` array and a
 * `nested` array. Both feed the one `items` table.
 * ------------------------------------------------------------------ */

static const char* aowl_ov_jraw(const char* v, const char* end,
                                char* out, int32_t cap) {
    const char* ve;
    int32_t n;
    out[0] = 0;
    if (!v) return NULL;
    v = aowl_ov_jws(v, end);
    ve = aowl_ov_jval_end(v, end);
    n = (int32_t)(ve - v);
    if (n < 0) n = 0;
    if (n > cap - 1) n = cap - 1;
    memcpy(out, v, (size_t)n);
    out[n] = 0;
    return ve;
}

/* Finite: not NaN, not +/-inf. Written without <math.h> so this header keeps
 * its "no library beyond what the host already links" property. `f != f` is
 * only true for NaN; the magnitude test catches both infinities. */
static int32_t aowl_ov_finite(float f) {
    if (f != f) return 0;
    return (f < 3.0e38f && f > -3.0e38f);
}

/* The most discrete steps a 104-pixel track is allowed to span. Past this the
 * slider cannot address its own values and the stepper is the honest control. */
#define AOWL_OV_SLIDER_MAX_STEPS 100000

static float aowl_ov_jfloat(const char* v, const char* end, float dflt) {
    char tmp[48];
    int32_t i = 0;
    if (!v) return dflt;
    v = aowl_ov_jws(v, end);
    while (v < end && i < 47 &&
           (*v == '-' || *v == '+' || *v == '.' || *v == 'e' || *v == 'E' ||
            (*v >= '0' && *v <= '9'))) tmp[i++] = *v++;
    tmp[i] = 0;
    if (!i) return dflt;
    return (float)strtod(tmp, NULL);
}

static int32_t aowl_ov_skind(const char* t) {
    if (!strcmp(t, "bool"))    return AOWL_S_BOOL;
    if (!strcmp(t, "int"))     return AOWL_S_INT;
    if (!strcmp(t, "float"))   return AOWL_S_FLOAT;
    if (!strcmp(t, "enum"))    return AOWL_S_ENUM;
    if (!strcmp(t, "string"))  return AOWL_S_STRING;
    if (!strcmp(t, "keybind")) return AOWL_S_KEYBIND;
    return AOWL_S_NESTED;    /* an SPT list/dict, or a type we do not draw */
}

/* `raw`, unquoted, for a row's display cell. Numbers and bools pass through;
 * strings, enums and keybinds lose their surrounding quotes. */
/* `value` (what the row prints) derived from `raw` (the JSON literal it
 * displays). Deliberately does NOT touch `auth` or `pend`, so the optimistic
 * overlay can re-derive the printed text after replacing `raw` without
 * disturbing the authoritative value the verify reads. */
static void aowl_ov_sval_text(AowlOvSItem* si) {
    if ((si->kind == AOWL_S_STRING || si->kind == AOWL_S_ENUM ||
         si->kind == AOWL_S_KEYBIND) && si->raw[0] == '"') {
        int32_t n = (int32_t)strlen(si->raw);
        if (n >= 2 && si->raw[n - 1] == '"') {
            memmove(si->value, si->raw + 1, (size_t)(n - 2));
            si->value[n - 2] = 0;
            return;
        }
    }
    aowl_ov_copy(si->value, (int32_t)sizeof(si->value), si->raw);
}

static void aowl_ov_sval_display(AowlOvSItem* si) {
    /* The ONLY place `auth` is ever written, and it is written from the parsed
     * document before any optimistic overlay can touch `raw`. See the comment
     * on `AowlOvSItem::auth`. */
    aowl_ov_copy(si->auth, (int32_t)sizeof(si->auth), si->raw);
    si->pend = AOWL_OV_PEND_NONE;
    aowl_ov_sval_text(si);
}

/* ------------------------------------------------------------------ *
 * The optimistic edit
 * ------------------------------------------------------------------ */

static void aowl_ov_pend_clear(void) {
    int32_t i;
    for (i = 0; i < AOWL_OV_PEND_MAX; i++) {
        g_ov.opt[i].page[0] = 0;
        g_ov.opt[i].key[0]  = 0;
        g_ov.opt[i].raw[0]  = 0;
        g_ov.opt[i].state   = AOWL_OV_PEND_NONE;
    }
    g_ov.optCountP = 0;
}

/* The entry for `key` on `page`, or -1. Capped by construction. */
static int32_t aowl_ov_pend_find(const char* page, const char* key) {
    int32_t i;
    if (!key || !key[0]) return -1;
    for (i = 0; i < g_ov.optCountP && i < AOWL_OV_PEND_MAX; i++) {
        if (g_ov.opt[i].state == AOWL_OV_PEND_NONE) continue;
        if (strcmp(g_ov.opt[i].key, key) != 0) continue;
        if (page && strcmp(g_ov.opt[i].page, page) != 0) continue;
        return i;
    }
    return -1;
}

/* Called the instant an edit is ISSUED -- from the UI thread at queue time and
 * again on the worker before the POST -- so that neither the wait behind an
 * earlier edit nor the re-GET the POST performs can paint the old value back.
 * Re-beginning the same page+key overwrites that entry in place, which is what
 * a player dragging one slider does and must not consume eight entries.
 *
 * Returns 0 and leaves a reason in `writeWhy` when the set is full: refusing
 * loudly is the only acceptable behaviour left, since the failure this
 * replaces was a drop nobody could see. */
static int32_t aowl_ov_pend_begin(const char* page, const char* key,
                                  const char* raw) {
    int32_t i;
    if (!key || !key[0]) return 0;
    i = aowl_ov_pend_find(page, key);
    if (i < 0) {
        for (i = 0; i < AOWL_OV_PEND_MAX; i++)
            if (i >= g_ov.optCountP || g_ov.opt[i].state == AOWL_OV_PEND_NONE)
                break;
        if (i >= AOWL_OV_PEND_MAX) {
            aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                        "NOT SENT: %d edits are already in flight, which is "
                        "this panel's limit. Nothing was lost and nothing was "
                        "changed -- wait for one to settle and set %s again.",
                        (int32_t)AOWL_OV_PEND_MAX, key);
            return 0;
        }
        if (i >= g_ov.optCountP) g_ov.optCountP = i + 1;
    }
    aowl_ov_copy(g_ov.opt[i].page, (int32_t)sizeof(g_ov.opt[i].page),
                 page ? page : "");
    aowl_ov_copy(g_ov.opt[i].key,  (int32_t)sizeof(g_ov.opt[i].key),  key);
    aowl_ov_copy(g_ov.opt[i].raw,  (int32_t)sizeof(g_ov.opt[i].raw),
                 raw ? raw : "");
    g_ov.opt[i].state = AOWL_OV_PEND_SAVING;
    return 1;
}

/* Record the verdict the verify ladder reached. `state` is one of the three
 * AOWL_OV_PEND_* outcomes; NONE means the value was confirmed and the row goes
 * back to being an ordinary row. */
static void aowl_ov_pend_settle(const char* skey, int32_t state) {
    int32_t i;
    int32_t slot;
    char key[80];
    /* SETTLE BY KEY, never "the one in flight". With more than one edit in
     * flight the latter attributes edit A's verdict to row B, which is the
     * concurrent-edit corruption this signature exists to make impossible. */
    if (!skey || !skey[0]) return;
    aowl_ov_copy(key, (int32_t)sizeof(key), skey);
    slot = aowl_ov_pend_find(NULL, key);
    if (slot < 0) return;
    /* The verdict must reach the screen NOW, not on whatever load happens
     * next: a row that is still badged SAVING thirty seconds after the verdict
     * is the same lie in the other direction. Never called with `cs` held --
     * `aowl_ov_settings_load` takes and releases it itself. */
    EnterCriticalSection(&g_ov.cs);
    for (i = 0; i < g_ov.itemCount; i++) {
        AowlOvSItem* si = &g_ov.items[i];
        if (strcmp(si->key, key) != 0) continue;
        si->pend = state;
        if (state != AOWL_OV_PEND_SAVING) {
            /* Back to the authoritative value on every non-SAVING outcome,
             * including a confirmed one -- where `auth` and the overlay are by
             * definition the same text, so this is a no-op that cannot drift.
             * On REJECTED/UNKNOWN it is the whole point. */
            aowl_ov_copy(si->raw, (int32_t)sizeof(si->raw), si->auth);
            aowl_ov_sval_text(si);
        }
        break;
    }
    if (state == AOWL_OV_PEND_NONE) {
        /* Only THIS entry retires. Clearing the whole set here is what used to
         * strand a second in-flight edit with a badge nothing would ever
         * update. */
        g_ov.opt[slot].page[0] = 0;
        g_ov.opt[slot].key[0]  = 0;
        g_ov.opt[slot].raw[0]  = 0;
        g_ov.opt[slot].state   = AOWL_OV_PEND_NONE;
        while (g_ov.optCountP > 0 &&
               g_ov.opt[g_ov.optCountP - 1].state == AOWL_OV_PEND_NONE)
            g_ov.optCountP--;
    } else {
        g_ov.opt[slot].state = state;
    }
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

/* Stamp the in-flight edit onto the freshly parsed rows. Called at the END of
 * `aowl_ov_read_items`, under `cs`, on every load -- which is the point: the
 * re-GET at t+1 s and every re-GET the verify loop performs all run through
 * here, so none of them can put the stale value back on screen.
 *
 * While SAVING it replaces the DISPLAYED literal only. After a verdict it
 * leaves the served value alone -- a rejected edit must show the value that
 * actually holds, not the one that was asked for -- and only tags the row so
 * the draw can say the edit was not accepted. Silent snap-back is the failure
 * mode this whole change exists to remove; a snap-back that ANNOUNCES itself
 * is the correct behaviour. */
static void aowl_ov_pend_apply(void) {
    int32_t i, p;
    for (p = 0; p < g_ov.optCountP && p < AOWL_OV_PEND_MAX; p++) {
        AowlOvPend* pd = &g_ov.opt[p];
        if (pd->state == AOWL_OV_PEND_NONE || !pd->key[0]) continue;
        if (strcmp(g_ov.itemsPage, pd->page) != 0) continue;
        for (i = 0; i < g_ov.itemCount; i++) {
            AowlOvSItem* si = &g_ov.items[i];
            if (strcmp(si->key, pd->key) != 0) continue;
            si->pend = pd->state;
            if (pd->state == AOWL_OV_PEND_SAVING) {
                aowl_ov_copy(si->raw, (int32_t)sizeof(si->raw), pd->raw);
                aowl_ov_sval_text(si);      /* never touches `auth` */
            }
            break;
        }
    }
}

/* One control object into one slot. Returns 1 on a usable row. */
/* ------------------------------------------------------------------ *
 * Group paths, to arbitrary depth
 * ------------------------------------------------------------------ */

/* Append `seg` to `out` as a path segment, skipping empties and collapsing
 * separators. Returns the new segment count. */
static int32_t aowl_ov_path_add(char* out, int32_t cap, int32_t depth,
                                const char* seg) {
    int32_t n = (int32_t)strlen(out), i = 0;
    while (seg[i]) {
        int32_t j = i, any = 0;
        while (seg[j] && seg[j] != '/') j++;
        if (j > i) {
            if (n > 0 && n < cap - 2) out[n++] = '/';
            for (; i < j && n < cap - 1; i++) { out[n++] = seg[i]; any = 1; }
            if (any) depth++;
        }
        i = j;
        while (seg[i] == '/') i++;
    }
    out[n] = 0;
    return depth;
}

/* The `d`-segment prefix of `path`, into `out`. `d` past the end yields the
 * whole path. */
static void aowl_ov_path_prefix(const char* path, int32_t d, char* out,
                                int32_t cap) {
    int32_t n = 0, seen = 0, i;
    for (i = 0; path[i] && n < cap - 1; i++) {
        if (path[i] == '/') { if (++seen >= d) break; }
        out[n++] = path[i];
    }
    out[n] = 0;
}

/* The last segment of `path`. */
static const char* aowl_ov_path_leaf(const char* path) {
    const char* q = strrchr(path, '/');
    return q ? q + 1 : path;
}

/* True when `pre` is `path` or an ancestor of it -- a SEGMENT-wise prefix, so
 * "Play" is not an ancestor of "Player/Health". */
static int32_t aowl_ov_path_under(const char* path, const char* pre) {
    size_t n;
    if (!pre[0]) return 1;
    n = strlen(pre);
    return strncmp(path, pre, n) == 0 && (path[n] == 0 || path[n] == '/');
}

static int32_t aowl_ov_read_one_item(const char* it, const char* end,
                                     AowlOvSItem* si) {
    const char* v;
    char t[24];
    memset(si, 0, sizeof(*si));
    si->lo = 0.0f; si->hi = 0.0f; si->step = 0.0f;
    si->hasRange = 0; si->optCount = 0; si->implemented = 1;

    aowl_ov_jput(it, end, "key", si->key, (int32_t)sizeof(si->key));
    if (!si->key[0]) return 0;
    aowl_ov_jput(it, end, "label", si->label, (int32_t)sizeof(si->label));
    if (!si->label[0]) aowl_ov_copy(si->label, (int32_t)sizeof(si->label), si->key);

    t[0] = 0;
    v = aowl_ov_jmem(it, end, "type");
    if (v) aowl_ov_jtext(v, end, t, (int32_t)sizeof(t));
    si->kind = aowl_ov_skind(t);

    /* The value, then the default as its fallback -- an SPT row carries neither
     * and stays blank, which is right for a row nobody can edit. */
    v = aowl_ov_jmem(it, end, "value");
    if (!v) v = aowl_ov_jmem(it, end, "default");
    if (v) aowl_ov_jraw(v, end, si->raw, (int32_t)sizeof(si->raw));
    aowl_ov_sval_display(si);

    /* THE RANGE, and what a missing one MEANS.
     *
     * A slider is a promise that every value the control can reach is a legal
     * value and that the two ends are the limits. When the schema does not say
     * what the limits are, the panel does NOT invent them: there is no honest
     * default for "how big can this number be", and 0..100 under a number whose
     * real domain is 1..3 or 0..2,000,000 is a lie the player cannot see. So a
     * row with no declared range gets the STEPPER and the type box instead --
     * both of which are exact and neither of which claims a bound.
     *
     * "Declared" means BOTH ends. `min` alone used to leave `hi` at 0 and get
     * caught by the `hi <= lo` test below only by luck; `max` alone silently
     * invented `min: 0`, which is the invented-bound case this rule exists to
     * refuse. Three further shapes are refused for the same reason -- the
     * control they would produce cannot address its own values:
     *
     *   * a non-finite end (NaN/inf out of a malformed body): `t` comes out NaN
     *     and the handle is drawn at an undefined x.
     *   * `hi <= lo`: a zero or inverted span; `t` divides by zero.
     *   * more than AOWL_OV_SLIDER_MAX_STEPS discrete steps in the span. The
     *     track is 104 px, so a span of 1e9 moves ~10,000,000 per pixel: the
     *     player can reach 104 of the values and no others, and the 3 they
     *     wanted is not among them.
     *
     * In every refused case `hasRange` is 0, which is already the "no range"
     * path everywhere downstream -- there is one representation of "unbounded",
     * not two. */
    {
        int32_t hasLo = 0, hasHi = 0;
        v = aowl_ov_jmem(it, end, "min");
        if (v) { si->lo = aowl_ov_jfloat(v, end, 0.0f); hasLo = 1; }
        v = aowl_ov_jmem(it, end, "max");
        if (v) { si->hi = aowl_ov_jfloat(v, end, 0.0f); hasHi = 1; }
        v = aowl_ov_jmem(it, end, "step");
        if (v) si->step = aowl_ov_jfloat(v, end, 0.0f);
        if (si->step <= 0.0f || !aowl_ov_finite(si->step))
            si->step = (si->kind == AOWL_S_FLOAT) ? 0.01f : 1.0f;
        si->hasRange = hasLo && hasHi;
        if (si->hasRange &&
            (!aowl_ov_finite(si->lo) || !aowl_ov_finite(si->hi) ||
             si->hi <= si->lo ||
             (si->hi - si->lo) / si->step > (float)AOWL_OV_SLIDER_MAX_STEPS))
            si->hasRange = 0;
    }

    v = aowl_ov_jmem(it, end, "options");
    if (v) {
        const char* o;
        for (o = aowl_ov_jarr(v, end); o && si->optCount < AOWL_OV_SOPT_MAX;
             o = aowl_ov_jnext(o, end))
            aowl_ov_jtext(o, end, si->opts[si->optCount++], 28);
    }
    aowl_ov_jput(it, end, "category", si->category, (int32_t)sizeof(si->category));
    /* Optional and emitted only when a mod sets it (`aowl/src/aowlspt/settings.nim`
     * `toJson`), so its absence is normal and must not read as an empty group. */
    aowl_ov_jput(it, end, "subcategory", si->subcat, (int32_t)sizeof(si->subcat));
    aowl_ov_jput(it, end, "description", si->desc, (int32_t)sizeof(si->desc));
    v = aowl_ov_jmem(it, end, "implemented");
    if (v) si->implemented = aowl_ov_jbool(v, end, 1);

    /* The group path. `path` when the backend sends one -- it is the
     * authoritative, already-ordered form -- and otherwise the identical rule
     * applied to `category` then `subcat`, so nothing regresses against a
     * backend that predates the field. Either way empty segments are dropped
     * by `aowl_ov_path_add`, so no group can end up nameless. */
    si->path[0] = 0; si->depth = 0;
    v = aowl_ov_jmem(it, end, "path");
    if (v) {
        const char* o;
        char one[80];
        for (o = aowl_ov_jarr(v, end); o && si->depth < 12;
             o = aowl_ov_jnext(o, end)) {
            aowl_ov_jtext(o, end, one, (int32_t)sizeof(one));
            si->depth = aowl_ov_path_add(si->path, (int32_t)sizeof(si->path),
                                         si->depth, one);
        }
    }
    if (!si->path[0]) {
        si->depth = aowl_ov_path_add(si->path, (int32_t)sizeof(si->path),
                                     si->depth, si->category);
        si->depth = aowl_ov_path_add(si->path, (int32_t)sizeof(si->path),
                                     si->depth, si->subcat);
    }
    if (!si->path[0]) {
        /* Ungrouped rows get a real group with a real name rather than an
         * empty one. "no group renders without a title" has to be true of the
         * rows that declared nothing too, or it is not a property of the
         * screen, only of the well-behaved half of it. */
        aowl_ov_copy(si->path, (int32_t)sizeof(si->path), "General");
        si->depth = 1;
    }
    return 1;
}

/* Order `items` by (category, subcategory), preserving declaration order inside
 * a subcategory. An insertion sort: bounded, in place, no allocation, and at
 * AOWL_OV_MAX_SITEMS rows the worst case is a few million byte compares on a
 * worker thread once per page load -- not on the render thread and not per
 * frame. The sort is what makes a category a CONTIGUOUS range, which is the
 * whole reason the sub-tab filter below can be two integers. Called under `cs`. */
static int32_t aowl_ov_scmp(const AowlOvSItem* a, const AowlOvSItem* b) {
    /* By the WHOLE path, which generalises the old (category, subcategory)
     * compare to any depth and keeps the property the rest of this file is
     * built on: `/` is 0x2F, below every letter and digit, so every PREFIX of
     * the sorted order is itself a contiguous half-open range. That is what
     * lets a tree node -- at any depth -- still be two integers, and it is why
     * `selItem` stays a flat item index and not one edit path below had to
     * change. */
    return strcmp(a->path, b->path);
}

static void aowl_ov_sort_items(void) {
    int32_t i, j;
    static AowlOvSItem tmp;   /* 1 KB; the worker's own, never re-entered */
    for (i = 1; i < g_ov.itemCount; i++) {
        tmp = g_ov.items[i];
        for (j = i - 1; j >= 0 && aowl_ov_scmp(&g_ov.items[j], &tmp) > 0; j--)
            g_ov.items[j + 1] = g_ov.items[j];
        g_ov.items[j + 1] = tmp;
    }
}

/* The nav TREE for the loaded page: one node per distinct path PREFIX, at any
 * depth, in the sorted order, each holding the half-open range of rows beneath
 * it. Replaces the old one-node-per-category table; a two-level schema
 * produces exactly the nodes it used to, so nothing about the existing pages
 * changes shape.
 *
 * `lo`/`hi` are the WHOLE subtree, so selecting "Player" shows every row under
 * "Player/Health/Regen" as well -- which is what makes a parent node useful
 * rather than empty. `direct` counts only the rows sitting exactly at that
 * path, which is what tells a group that has rows from one that is purely
 * structural.
 *
 * Every node`s parent is recorded and is guaranteed to EXIST: a node is only
 * ever emitted after each of its shorter prefixes has been. That is what the
 * invariant "no nav node is unreachable by breadcrumb" reduces to, and it is
 * asserted rather than assumed -- see `aowl_ov_cats_wellformed`.
 *
 * Called under `cs`. */
#define AOWL_OV_MAX_DEPTH 12

static void aowl_ov_build_cats(void) {
    int32_t i, d, k;
    int32_t openAt[AOWL_OV_MAX_DEPTH + 2];
    char    pre[160];
    for (d = 0; d < AOWL_OV_MAX_DEPTH + 2; d++) openAt[d] = -1;
    g_ov.catCount = 0;
    for (i = 0; i < g_ov.itemCount; i++) {
        AowlOvSItem* si = &g_ov.items[i];
        int32_t dep = si->depth;
        if (dep > AOWL_OV_MAX_DEPTH) dep = AOWL_OV_MAX_DEPTH;
        if (dep < 1) dep = 1;
        for (d = 1; d <= dep; d++) {
            AowlOvSCat* C;
            aowl_ov_path_prefix(si->path, d, pre, (int32_t)sizeof(pre));
            if (openAt[d] >= 0 && strcmp(g_ov.cats[openAt[d]].full, pre) == 0) {
                g_ov.cats[openAt[d]].hi = i + 1;
                continue;
            }
            if (g_ov.catCount >= AOWL_OV_MAX_SCATS) {
                /* Out of nodes: the rest of the page joins whatever is still
                 * open rather than disappearing. A row that exists and is
                 * unreachable is the failure this branch exists to not have. */
                for (k = 1; k <= AOWL_OV_MAX_DEPTH; k++)
                    if (openAt[k] >= 0) g_ov.cats[openAt[k]].hi = g_ov.itemCount;
                return;
            }
            C = &g_ov.cats[g_ov.catCount];
            memset(C, 0, sizeof(*C));
            aowl_ov_copy(C->full, (int32_t)sizeof(C->full), pre);
            aowl_ov_copy(C->label, (int32_t)sizeof(C->label),
                         aowl_ov_path_leaf(pre));
            C->depth = d;
            C->parent = (d > 1) ? openAt[d - 1] : -1;
            C->lo = i; C->hi = i + 1; C->direct = 0;
            openAt[d] = g_ov.catCount++;
            /* Everything deeper that was open belongs to a different branch
             * now. Not clearing these is how a node inherits a parent from the
             * previous branch and the breadcrumb starts lying. */
            for (k = d + 1; k <= AOWL_OV_MAX_DEPTH + 1; k++) openAt[k] = -1;
        }
        if (openAt[dep] >= 0) g_ov.cats[openAt[dep]].direct++;
    }
}

/* PASS / FAIL for the properties the nav must have, computed from the FINISHED
 * table rather than from the loop that built it. Returns 0 when something is
 * wrong and writes which; the caller records it and the panel prints it.
 * Deliberately negative: it looks for a node that CANNOT be reached, not for
 * one that can.
 *
 *   * no node has an empty label -- "no group renders without a title";
 *   * every node deeper than 1 has a parent index that exists and whose `full`
 *     is exactly this node`s path minus its last segment, so walking `parent`
 *     from any node terminates at a top-level node. That walk IS the
 *     breadcrumb, which is what makes this "no nav node is unreachable by
 *     breadcrumb" and not a restatement of the builder;
 *   * the depth-1 nodes partition the rows -- no row is under no group, and
 *     none is under two.
 *
 * It can fail: give it two rows whose paths are "A/B" and "B" and set
 * AOWL_OV_MAX_SCATS to 1 and the first branch fires; corrupt any `parent` and
 * the third does; drop the "General" fallback in `read_one_item` and the first
 * and last both do. `tests/overlayhost` mutates exactly these. */
static int32_t aowl_ov_cats_wellformed(char* why, int32_t cap) {
    int32_t i, covered = 0;
    char pre[160];
    if (why && cap > 0) why[0] = 0;
    for (i = 0; i < g_ov.catCount; i++) {
        AowlOvSCat* C = &g_ov.cats[i];
        if (!C->label[0]) {
            if (why) aowl_ov_fmt(why, cap, "nav node %d has no title", i);
            return 0;
        }
        if (C->hi <= C->lo || C->lo < 0 || C->hi > g_ov.itemCount) {
            if (why) aowl_ov_fmt(why, cap, "nav node %s spans [%d,%d)",
                                 C->full, C->lo, C->hi);
            return 0;
        }
        if (C->depth == 1) { covered += C->hi - C->lo; continue; }
        if (C->parent < 0 || C->parent >= g_ov.catCount) {
            if (why) aowl_ov_fmt(why, cap, "nav node %s has no parent", C->full);
            return 0;
        }
        aowl_ov_path_prefix(C->full, C->depth - 1, pre, (int32_t)sizeof(pre));
        if (strcmp(g_ov.cats[C->parent].full, pre) != 0) {
            if (why) aowl_ov_fmt(why, cap, "nav node %s claims parent %s",
                                 C->full, g_ov.cats[C->parent].full);
            return 0;
        }
    }
    if (covered != g_ov.itemCount) {
        if (why) aowl_ov_fmt(why, cap,
                             "%d of %d rows are under no top-level group",
                             g_ov.itemCount - covered, g_ov.itemCount);
        return 0;
    }
    return 1;
}

/* Fill `items` from a page body -- a bare array (a mod's schema) or an object
 * carrying `settings` and `nested` (an SPT page). Called under `cs`. */
static void aowl_ov_read_items(const char* body, int32_t len) {
    const char* end = body + len;
    const char* p = aowl_ov_jws(body, end);
    const char* arr;
    g_ov.itemCount = 0;
    g_ov.itemsImpl = 0;
    g_ov.hiddenCount = 0;
    if (p >= end) return;

    if (*p == '[') {
        arr = aowl_ov_jarr(p, end);
    } else {
        /* THE REFUSAL SHAPE. `declaredSchemaReply` in
         * `aowl/src/aowlspt/settings.nim` answers `{"err":..,"rows":[..]}`
         * when a write did NOT persist, and answers the bare array when it
         * did. This reader knew only `[` and `{"settings":..}`, so a refusal
         * parsed as a page with zero rows -- a blank pane, which reads as "this
         * mod has no settings" and is the opposite of what happened. `rows` is
         * read like any other array and `err` is surfaced verbatim, in the
         * server's own words. */
        const char* e = aowl_ov_jmem(p, end, "err");
        arr = aowl_ov_jmem(p, end, "settings");
        if (!arr) arr = aowl_ov_jmem(p, end, "rows");
        arr = arr ? aowl_ov_jarr(arr, end) : NULL;
        if (e) {
            char ebuf[160];
            ebuf[0] = 0;
            aowl_ov_jtext(e, end, ebuf, (int32_t)sizeof(ebuf));
            if (ebuf[0]) {
                aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                            "the server REFUSED this write: %s", ebuf);
                aowl_ov_note(g_ov.writeWhy);
            }
        }
    }
    for (; arr && g_ov.itemCount < AOWL_OV_MAX_SITEMS; arr = aowl_ov_jnext(arr, end)) {
        AowlOvSItem* si = &g_ov.items[g_ov.itemCount];
        if (aowl_ov_read_one_item(arr, end, si)) {
            /* THE UNIMPLEMENTED FILTER, and it is applied HERE -- at parse
             * time, before sorting and before the nav tree is built -- rather
             * than in the draw.
             *
             * Filtering in the draw would have had to leave the row in `items`,
             * which means `sCats[c].lo/hi` still spans it, the group band still
             * counts it, `viewLo/viewHi` still let the cursor land on it and
             * PgDn still pages over it. Every one of those is a place the
             * count on screen and the rows on screen could disagree. Dropping
             * the row before `sort_items`/`build_cats` run means a group that
             * held nothing but hidden rows is never CREATED, so "do not render
             * a group left empty" needs no code at all -- it is unrepresentable.
             *
             * The filter is on the DATA (`implemented`), never on a name. */
            if (!si->implemented && !g_ov.showUnimpl) {
                g_ov.hiddenCount++;
                continue;
            }
            if (si->implemented) g_ov.itemsImpl++;
            g_ov.itemCount++;
        }
    }
    /* SPT `nested` rows: lists and dicts, edited as raw JSON elsewhere, listed
     * here for completeness and always not-implemented. */
    if (*p == '{') {
        const char* nst = aowl_ov_jmem(p, end, "nested");
        nst = nst ? aowl_ov_jarr(nst, end) : NULL;
        for (; nst && g_ov.itemCount < AOWL_OV_MAX_SITEMS; nst = aowl_ov_jnext(nst, end)) {
            AowlOvSItem* si = &g_ov.items[g_ov.itemCount];
            const char* v;
            char ty[40];
            if (!aowl_ov_read_one_item(nst, end, si)) continue;
            si->kind = AOWL_S_NESTED;
            si->implemented = 0;
            ty[0] = 0;
            v = aowl_ov_jmem(nst, end, "type");
            if (v) aowl_ov_jtext(v, end, ty, (int32_t)sizeof(ty));
            if (ty[0]) aowl_ov_copy(si->value, (int32_t)sizeof(si->value), ty);
            if (!si->desc[0])
                aowl_ov_copy(si->desc, (int32_t)sizeof(si->desc),
                             "a nested list/dictionary; edited as raw JSON, "
                             "not implemented in aowlspt yet");
            /* Nested rows are unconditionally not-implemented, so they obey the
             * same filter as everything else rather than a rule of their own. */
            if (!g_ov.showUnimpl) { g_ov.hiddenCount++; continue; }
            g_ov.itemCount++;
        }
    }
    aowl_ov_sort_items();
    aowl_ov_build_cats();
    /* AFTER the sort, so the row that gets stamped is the row that will draw. */
    aowl_ov_pend_apply();
    /* Check the FINISHED nav, every load, and say so on the panel when it is
     * wrong. A tree that quietly loses a branch is the exact failure mode this
     * screen has had before: a row that exists, is not on any page, and nobody
     * finds out. `itemsWhy` is the line the right pane already prints. */
    {
        char why[192];
        if (!aowl_ov_cats_wellformed(why, (int32_t)sizeof(why))) {
            aowl_ov_fmt(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                        "nav tree is malformed: %s", why);
            aowl_ov_note(g_ov.itemsWhy);
        }
    }
}

/* The SPT page index: `{"pages":[{"id","label","count","done"}...]}`. Called
 * under `cs`. */
static void aowl_ov_read_spt_index(const char* body, int32_t len) {
    const char* end = body + len;
    const char* pg = aowl_ov_jmem(body, end, "pages");
    pg = pg ? aowl_ov_jarr(pg, end) : NULL;
    g_ov.sptPageCount = 0;
    for (; pg && g_ov.sptPageCount < AOWL_OV_MAX_SPAGES; pg = aowl_ov_jnext(pg, end)) {
        AowlOvSPage* P = &g_ov.sptPages[g_ov.sptPageCount];
        const char* v;
        memset(P, 0, sizeof(*P));
        aowl_ov_jput(pg, end, "id", P->id, (int32_t)sizeof(P->id));
        if (!P->id[0]) continue;
        aowl_ov_jput(pg, end, "label", P->label, (int32_t)sizeof(P->label));
        if (!P->label[0]) aowl_ov_copy(P->label, (int32_t)sizeof(P->label), P->id);
        P->isMod = 0;
        v = aowl_ov_jmem(pg, end, "count"); P->count = v ? aowl_ov_jint(v, end, -1) : -1;
        v = aowl_ov_jmem(pg, end, "done");  P->done  = v ? aowl_ov_jint(v, end, -1) : -1;
        g_ov.sptPageCount++;
    }
    g_ov.sptGot = 1;
}

/* The settings index: `{"mods":[{"guid","name","count"}...]}`. Called under
 * `cs`. Every entry here is a mod that answered the index broadcast, which is
 * to say a mod that declared at least one setting -- see `onIndexQuery` in
 * `aowl/src/aowlspt/settings.nim`, which only subscribes when `declareSettings`
 * was called with a non-empty list. */
static void aowl_ov_read_settings_index(const char* body, int32_t len) {
    const char* end = body + len;
    const char* m = aowl_ov_jmem(body, end, "mods");
    m = m ? aowl_ov_jarr(m, end) : NULL;
    g_ov.idxModCount = 0;
    for (; m && g_ov.idxModCount < AOWL_OV_MAX_SPAGES; m = aowl_ov_jnext(m, end)) {
        AowlOvSPage* P = &g_ov.idxMods[g_ov.idxModCount];
        const char* v;
        memset(P, 0, sizeof(*P));
        aowl_ov_jput(m, end, "guid", P->id, (int32_t)sizeof(P->id));
        if (!P->id[0]) continue;
        aowl_ov_jput(m, end, "name", P->label, (int32_t)sizeof(P->label));
        if (!P->label[0]) aowl_ov_copy(P->label, (int32_t)sizeof(P->label), P->id);
        P->isMod = 1;
        v = aowl_ov_jmem(m, end, "count"); P->count = v ? aowl_ov_jint(v, end, -1) : -1;
        /* `done` used to be hardcoded to -1 here, because no mod sent one. One
         * does now (`onIndexQuery` in `aowl/src/aowlspt/settings.nim`), and the
         * absent case still lands on -1 through the same expression the SPT
         * index uses -- so "the index did not say" stays distinguishable from
         * "it said none", which is the distinction the page filter turns on. */
        v = aowl_ov_jmem(m, end, "done");  P->done  = v ? aowl_ov_jint(v, end, -1) : -1;
        g_ov.idxModCount++;
    }
    g_ov.idxGot = 1;
    g_ov.idxWhy[0] = 0;
}

/* Merge the nav: one page per mod THAT PUBLISHES SETTINGS, then the SPT pages
 * the hub described. Called under `cs` whenever either half moves.
 *
 * It used to walk `g_ov.mods` -- the client mod roster -- which is a different
 * question with a different answer: the roster carries `aowl.manager`,
 * `aowl.settingshub`, `aowl.uihub` and every not-selected mod, so the settings
 * nav listed five pages a player cannot configure and four of them opened on an
 * error. There is deliberately NO fallback to the roster when the index is
 * missing: an empty nav that names the missing route is a true statement, and
 * the roster is a false one. */
/* A page NONE of whose rows would survive the unimplemented filter. Answered
 * from the INDEX -- `count` rows of which `done` are implemented -- so it costs
 * no fetch: hiding 28 SPT pages must not mean downloading 28 SPT pages to find
 * out they are empty.
 *
 * `done == -1` means THE INDEX DID NOT SAY, and is emphatically not the same as
 * `done == 0`. Only an explicit zero hides a page; an index that is silent
 * leaves the page visible, because the failure mode of guessing here is a page
 * the player cannot reach and cannot be told about. `mods/settingshub`'s
 * `onIndex` sends `done: 0` for every SPT page (measured: all 323 settings and
 * 197 nested rows in `sptsurface.nim` carry `implemented:false`), and
 * `aowl/src/aowlspt/settings.nim`'s `onIndexQuery` now sends a real `done` for
 * each mod, so both halves answer this honestly rather than by page kind. */
static int32_t aowl_ov_page_all_hidden(const AowlOvSPage* P) {
    if (g_ov.showUnimpl) return 0;
    return P->count > 0 && P->done == 0;
}

static void aowl_ov_rebuild_pages(void) {
    int32_t i;
    g_ov.pageCount = 0;
    /* THE PANEL'S OWN PAGE, FIRST AND ALWAYS.
     *
     * Unconditional: it is the one page with no backend behind it, so it is
     * also the one page that is still there when the backend is down -- which
     * is exactly when somebody wants to turn the startup toast off or make the
     * panel readable. It is never subject to `aowl_ov_page_all_hidden`; every
     * row on it is implemented. */
    {
        AowlOvSPage* P = &g_ov.pages[g_ov.pageCount++];
        memset(P, 0, sizeof(*P));
        aowl_ov_copy(P->id, (int32_t)sizeof(P->id), AOWL_OV_PANEL_PAGE);
        aowl_ov_copy(P->label, (int32_t)sizeof(P->label), "Settings Panel");
        P->isMod = 1; P->count = 9; P->done = 9;
    }
    for (i = 0; i < g_ov.idxModCount && g_ov.pageCount < AOWL_OV_MAX_SPAGES; i++)
        if (!aowl_ov_page_all_hidden(&g_ov.idxMods[i]))
            g_ov.pages[g_ov.pageCount++] = g_ov.idxMods[i];
    for (i = 0; i < g_ov.sptPageCount && g_ov.pageCount < AOWL_OV_MAX_SPAGES; i++)
        if (!aowl_ov_page_all_hidden(&g_ov.sptPages[i]))
            g_ov.pages[g_ov.pageCount++] = g_ov.sptPages[i];
}

static int32_t aowl_ov_fetch(const wchar_t* verb, const wchar_t* path,
                             const char* body, char* out, int32_t cap) {
    int32_t rc;
    DWORD t0 = GetTickCount();
    InterlockedExchange(&g_ov.busy, 1);
    rc = aowl_ov_http(verb, path, body, out, cap);
    InterlockedExchange(&g_ov.busy, 0);
    /* Kept for both outcomes. A slow *success* and a fast *failure* are
     * different problems and the panel should be able to tell them apart
     * without a debugger. */
    InterlockedExchange(&g_ov.lastRttMs, (LONG)(GetTickCount() - t0));

    if (rc > 1 && (unsigned char)out[0] == 0x78) {
        /* A zlib stream, not JSON. Named exactly, because every other symptom
         * of it -- an empty panel, a "backend up" light over a read-only list
         * -- points at the wrong half of the system. */
        InterlockedExchange(&g_ov.backendOk, 0);
        aowl_ov_copy(g_ov.lastError, (int32_t)sizeof(g_ov.lastError),
                     "the backend answered with a deflated body; it must honour "
                     "Accept-Encoding: identity");
        aowl_ov_note("backend answered with a deflated body; it must honour "
                     "Accept-Encoding: identity (see host/Aowlspt.Overlay/README.md)");
        return -1;
    }
    if (rc <= 0) {
        InterlockedExchange(&g_ov.backendOk, 0);
        return -1;
    }
    InterlockedExchange(&g_ov.backendOk, 1);
    InterlockedExchange(&g_ov.everOk, 1);
    InterlockedExchange(&g_ov.lastOkTick, (LONG)GetTickCount());
    return rc;
}

/* Load one settings page's controls into `items`. `isMod` picks the route: a
 * mod serves its own schema at `/aowlspt/settings/<guid>`, the SPT pages come
 * from the hub. Runs on the worker; publishes under `cs` and bumps the serial
 * so the render thread snapshots it. */
/* ------------------------------------------------------------------ *
 * THE PANEL'S OWN SETTINGS PAGE
 *
 * The overlay is the one mod on this screen with no backend behind it, and for
 * a long time that meant it was the one thing on the screen you could not
 * configure from the screen: opacity was a key, the footer was not settable at
 * all, and the theme did not exist. Every one of those is now a row.
 *
 * It is a SYNTHETIC PAGE -- the same JSON shape a real mod serves, generated in
 * memory and handed to the same `aowl_ov_read_items` -- rather than a bespoke
 * view. That is the whole design: the tree, the groups, the sliders, the enum
 * cycling, the search, the keyboard bounds and the write coalescing are the
 * ones that already work, and a second implementation of any of them would be
 * a second thing to get wrong. It also means the page cannot drift from the
 * rest of the screen: if a control type renders badly here it renders badly
 * everywhere, and gets fixed once.
 *
 * There is no HTTP anywhere in this path, so this page works with the backend
 * down -- which is also when somebody is most likely to be poking at the panel.
 * ------------------------------------------------------------------ */

/* A string into a JSON literal, dropping anything that would need escaping.
 * Theme names come from files a user wrote, so a stray quote must not be able
 * to produce a body that does not parse -- and a name with a quote in it is not
 * worth a general escaper here. */
static void aowl_ov_jsafe(const char* s, char* out, int32_t cap) {
    int32_t n = 0;
    for (; *s && n < cap - 1; s++)
        if (*s >= ' ' && *s != '"' && *s != '\\') out[n++] = *s;
    out[n] = 0;
}

static void aowl_ov_panel_schema(char* out, int32_t cap) {
    int32_t n, i;
    char opts[1024];
    char one[64];
    /* The theme list is DATA-DRIVEN -- it is whatever `aowl_ov_themes_load`
     * found, built-ins plus every file in the themes folder. Nothing here
     * knows how many themes there are, which is the requirement: a user who
     * drops a fifth file in gets a fifth option with no code change. */
    opts[0] = 0; n = 0;
    for (i = 0; i < g_ovThemeCount; i++) {
        aowl_ov_jsafe(g_ovThemes[i].name, one, (int32_t)sizeof(one));
        if (!one[0]) continue;
        n += _snprintf(opts + n, sizeof(opts) - 1 - (size_t)n, "%s\"%s\"",
                       n ? "," : "", one);
        if (n < 0 || n > (int32_t)sizeof(opts) - 80) break;
    }
    opts[sizeof(opts) - 1] = 0;
    aowl_ov_jsafe(g_ov.themeName, one, (int32_t)sizeof(one));
    _snprintf(out, (size_t)cap - 1,
      "{\"settings\":["
      "{\"key\":\"theme\",\"label\":\"Theme\",\"type\":\"enum\","
        "\"value\":\"%s\",\"options\":[%s],\"category\":\"Appearance\","
        "\"description\":\"the panel's colour scheme. Built-ins plus every "
        "*.theme file in %%LOCALAPPDATA%%\\\\aowlspt\\\\themes -- copy one out, "
        "edit it, share the file.\",\"implemented\":true},"
      "{\"key\":\"opacity\",\"label\":\"Background opacity\",\"type\":\"int\","
        "\"value\":%d,\"min\":40,\"max\":255,\"step\":5,"
        "\"category\":\"Appearance\",\"description\":\"how solid the panel's "
        "background is. 255 hides the game behind it entirely.\","
        "\"implemented\":true},"
      "{\"key\":\"scalePref\",\"label\":\"UI scale\",\"type\":\"enum\","
        "\"value\":\"%s\",\"options\":[\"Auto\",\"1x\",\"2x\",\"3x\"],"
        "\"category\":\"Appearance\",\"description\":\"Auto picks from the "
        "back-buffer height, which is right for most screens and wrong for "
        "exactly the person who says so.\",\"implemented\":true},"
      "{\"key\":\"navW\",\"label\":\"Nav column width\",\"type\":\"int\","
        "\"value\":%d,\"min\":140,\"max\":640,\"step\":8,"
        "\"category\":\"Layout\",\"description\":\"how much of the panel the "
        "page tree gets. A deep tree spends its left edge on indent.\","
        "\"implemented\":true},"
      "{\"key\":\"showFooter\",\"label\":\"Show the footer\",\"type\":\"bool\","
        "\"value\":%s,\"category\":\"Layout\",\"description\":\"the key legend "
        "along the bottom. Off gives its height back to the list.\","
        "\"implemented\":true},"
      "{\"key\":\"savePos\",\"label\":\"Remember size and position\","
        "\"type\":\"bool\",\"value\":%s,\"category\":\"Layout\","
        "\"description\":\"off means the panel opens in the same place every "
        "time; it can still be dragged for this session.\","
        "\"implemented\":true},"
      "{\"key\":\"hint\",\"label\":\"Startup message\",\"type\":\"bool\","
        "\"value\":%s,\"category\":\"Behaviour\",\"description\":\"the 'Press "
        "F12 for Mod Settings' toast shown once after the backend answers.\","
        "\"implemented\":true},"
      "{\"key\":\"animate\",\"label\":\"Animate\",\"type\":\"bool\","
        "\"value\":%s,\"category\":\"Behaviour\",\"description\":\"off makes "
        "the startup message cut rather than fade. It is on screen for the "
        "same length of time either way.\",\"implemented\":true},"
      "{\"key\":\"showUnimpl\",\"label\":\"Show unimplemented settings\","
        "\"type\":\"bool\",\"value\":%s,\"category\":\"Behaviour\","
        "\"description\":\"rows a mod declared but does not act on yet. Off "
        "by default: a control that does nothing is worse than no control.\","
        "\"implemented\":true}"
      "]}",
      one, opts, g_ov.panAlpha,
      g_ov.scalePref == 0 ? "Auto" : g_ov.scalePref == 1 ? "1x"
                          : g_ov.scalePref == 2 ? "2x" : "3x",
      g_ov.navW,
      g_ov.showFooter ? "true" : "false",
      g_ov.savePos ? "true" : "false",
      g_ov.hintEnabled ? "true" : "false",
      g_ov.animate ? "true" : "false",
      g_ov.showUnimpl ? "true" : "false");
    out[cap - 1] = 0;
}

/* One edit from the panel page, applied to the live prefs. Returns 1 when the
 * key was one of ours -- an unknown key is REFUSED rather than ignored, so a
 * renamed row shows up as a row that stops working instead of a row that
 * silently writes nothing. */
static int32_t aowl_ov_panel_set(const char* key, const char* val) {
    /* `val` is the RAW schema value: quoted for enums, bare for numbers and
     * bools -- the same text `aowl_ov_settings_set` would have POSTed. */
    char v[64];
    int32_t n = 0;
    int32_t mirrorHint = 0;
    const char* p = val;
    if (*p == '"') p++;
    while (*p && *p != '"' && n < (int32_t)sizeof(v) - 1) v[n++] = *p++;
    v[n] = 0;
    if (!strcmp(key, "theme")) {
        if (aowl_ov_theme_find(v) < 0) return 0;
        aowl_ov_theme_apply(v);
    } else if (!strcmp(key, "opacity")) {
        int32_t a = atoi(v);
        if (a < 40 || a > 255) return 0;
        g_ov.panAlpha = a;
    } else if (!strcmp(key, "scalePref")) {
        g_ov.scalePref = !strcmp(v, "Auto") ? 0 : (v[0] >= '1' && v[0] <= '3')
                                                    ? v[0] - '0' : 0;
    } else if (!strcmp(key, "navW")) {
        int32_t a = atoi(v);
        if (a < 140 || a > 640) return 0;
        g_ov.navW = a;
    } else if (!strcmp(key, "showFooter")) g_ov.showFooter = (v[0] == 't' || v[0] == '1');
    else if (!strcmp(key, "savePos"))      g_ov.savePos    = (v[0] == 't' || v[0] == '1');
    else if (!strcmp(key, "hint")) {
        g_ov.hintEnabled = (v[0] == 't' || v[0] == '1');
        mirrorHint = 1;
    }
    else if (!strcmp(key, "animate"))      g_ov.animate    = (v[0] == 't' || v[0] == '1');
    else if (!strcmp(key, "showUnimpl")) {
        g_ov.showUnimpl = (v[0] == 't' || v[0] == '1');
        /* This one changes which PAGES exist, not just which rows do -- and
         * `pages` is read by the render thread, so the rebuild takes the lock
         * the HTTP path's rebuild already runs under. The theme write above
         * does not: `g_ovTheme` is sixteen independent uint32s and the worst a
         * torn copy can produce is one frame in two palettes, where taking a
         * lock in Present would be a frame spike the player feels. */
        EnterCriticalSection(&g_ov.cs);
        aowl_ov_rebuild_pages();
        LeaveCriticalSection(&g_ov.cs);
        g_ov.dataSerial++;
    } else return 0;
    /* THE LAUNCH TOAST'S OFF-SWITCH IS NOT DURABLE IN THE PREFS FILE ALONE.
     *
     * `hint` and `aowl.uihub`'s `launchHint` are the SAME value: both drive
     * `g_ov.hintEnabled`. But the worker re-fetches
     * `GET /aowlspt/settings/aowl.uihub` once per launch and OVERWRITES
     * whatever the prefs file remembered (see the `!g_ov.hintFetched` block
     * further down this file). So a `hint` write that only touched the prefs
     * file came back on every launch -- the row LOOKED like an off-switch and
     * was not one, which is exactly the silent-no-op shape CLAUDE.md 9b names.
     *
     * Mirroring it to the owner is what makes this row durable on its own, and
     * that is what let the duplicate "Settings Panel" proxy page in
     * `mods/settingshub` be deleted rather than merged.
     *
     * The value POSTed is `g_ov.hintEnabled` re-rendered as a BARE JSON bool,
     * never the caller's `v` text: `v` has already had its quotes stripped, so
     * forwarding it would persist the string "true" where a bool belongs, and
     * a value that persists with the wrong type reads back as truthy forever.
     *
     * One owner, still: uihub keeps the guid, the route and the config key.
     * This is a forward to the owner, not a second store. */
    if (mirrorHint) {
        char jbody[96];
        char resp[1024];
        int32_t rc;
        aowl_ov_fmt(jbody, (int32_t)sizeof(jbody),
                    "{\"key\":\"launchHint\",\"value\":%s}",
                    g_ov.hintEnabled ? "true" : "false");
        rc = aowl_ov_fetch(L"POST", L"/aowlspt/settings/aowl.uihub", jbody,
                           resp, (int32_t)sizeof(resp));
        /* BOTH outcomes are said out loud. A settings write that fails
         * silently is the defect class this project keeps hitting: the row
         * would flip on screen, persist to prefs, and be undone at the next
         * launch with nothing anywhere saying why. */
        aowl_ov_fmt(g_ov.hintWhy, (int32_t)sizeof(g_ov.hintWhy),
                    rc > 0
                      ? "launchHint WRITTEN to aowl.uihub = %d (durable)"
                      : "launchHint = %d applied to this session ONLY: "
                        "POST /aowlspt/settings/aowl.uihub did not answer, so "
                        "the next launch will re-read the old value",
                    g_ov.hintEnabled);
        aowl_ov_note(g_ov.hintWhy);
        /* Same kick the HTTP write path uses, so the settings bridge collects
         * this edit now instead of on its own five-second schedule. */
        InterlockedExchange(&g_ov.editKick, 1);
    }
    /* Every one of these persists, and it persists NOW rather than at exit --
     * a crash must not be able to eat a preference the player just set. This
     * runs on the worker, which is the only thread allowed to write the file. */
    aowl_ov_prefs_save();
    return 1;
}

static void aowl_ov_settings_load(const char* pageId, int32_t isMod,
                                  char* buf, int32_t cap) {
    wchar_t path[224];
    wchar_t warg[96];
    int32_t i = 0, rc, trunc;
    for (; pageId[i] && i < 95; i++) warg[i] = (wchar_t)(unsigned char)pageId[i];
    warg[i] = 0;
    if (isMod) _snwprintf(path, 224, L"/aowlspt/settings/%ls", warg);
    else       _snwprintf(path, 224, L"/aowlspt/settings/spt/page/%ls", warg);
    path[223] = 0;

    /* The panel's own page is generated, not fetched -- see
     * `aowl_ov_panel_schema`. Everything below this point is identical for it
     * and for a real mod, including the well-formedness check on the finished
     * nav, which is the point: the synthetic page is held to the same standard
     * as a served one. */
    if (!strcmp(pageId, AOWL_OV_PANEL_PAGE)) {
        aowl_ov_panel_schema(buf, cap);
        EnterCriticalSection(&g_ov.cs);
        /* A "did not take" banner belongs to the page it was measured on. It
         * is cleared on a page CHANGE only -- never on the re-read a write
         * itself performs, which is the read the banner is computed from. */
        if (strcmp(g_ov.itemsPage, pageId) != 0) {
            g_ov.writeWhy[0] = 0;
            aowl_ov_pend_clear();
        }
        aowl_ov_copy(g_ov.itemsPage, (int32_t)sizeof(g_ov.itemsPage), pageId);
        g_ov.itemsWhy[0] = 0;
        aowl_ov_read_items(buf, (int32_t)strlen(buf));
        g_ov.itemsErr = 0;
        LeaveCriticalSection(&g_ov.cs);
        g_ov.dataSerial++;
        return;
    }

    rc = aowl_ov_fetch(L"GET", path, NULL, buf, cap);
    trunc = (int32_t)InterlockedCompareExchange(&g_ov.lastTrunc, 0, 0);
    EnterCriticalSection(&g_ov.cs);
    if (strcmp(g_ov.itemsPage, pageId) != 0) {
        g_ov.writeWhy[0] = 0;
        aowl_ov_pend_clear();
    }
    aowl_ov_copy(g_ov.itemsPage, (int32_t)sizeof(g_ov.itemsPage), pageId);
    g_ov.itemsWhy[0] = 0;
    if (rc > 0 && (unsigned char)buf[0] != 0x78 && aowl_ov_jwhole(buf, rc)) {
        aowl_ov_read_items(buf, rc);
        g_ov.itemsErr = 0;
        if (g_ov.itemCount >= AOWL_OV_MAX_SITEMS)
            aowl_ov_fmt(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                        "this page has more rows than the panel can hold; "
                        "showing the first %d", AOWL_OV_MAX_SITEMS);
    } else {
        g_ov.itemCount = 0;
        g_ov.itemsImpl = 0;
        g_ov.catCount = 0;
        g_ov.itemsErr = 1;
        /* Three different faults used to arrive here indistinguishable. Named
         * separately now, because "it did not fit" and "nobody answered" send a
         * person to opposite ends of the system. */
        if (trunc > 0)
            aowl_ov_fmt(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                        "the reply was larger than the panel's %d-byte buffer "
                        "and arrived cut in half", trunc);
        else if (rc > 0 && (unsigned char)buf[0] == 0x78)
            aowl_ov_copy(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                         "the backend sent a deflated body; it must honour "
                         "Accept-Encoding: identity");
        else if (rc > 0)
            aowl_ov_copy(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                         "the backend answered, but not with a schema -- the "
                         "route may be missing on this mod");
        else
            aowl_ov_copy(g_ov.itemsWhy, (int32_t)sizeof(g_ov.itemsWhy),
                         "the backend did not answer at all");
    }
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

/* POST one edit to the mod that owns the page, then reload the page so the row
 * shows the value the file actually kept rather than the one we hoped for. */
/* DID THE WRITE ACTUALLY TAKE?
 *
 * Called on the worker straight after `aowl_ov_settings_set` has POSTed a key
 * and RE-READ the page, so `g_ov.items` already holds the finished state. It
 * compares what the row reads NOW against what was sent -- never the status
 * code, which is 200 on the silent-revert path and on the working one alike
 * (fact #135), and never the request we made, which is a self-comparison and
 * cannot fail.
 *
 * Three outcomes, not two: verified (clears the banner), NOT APPLIED (names
 * both values), and INCONCLUSIVE whenever the finished state could not be
 * OBSERVED -- the row was missing, the pipeline had not republished yet, or
 * the edit was still queued. "I could not look" is not a pass, and it is not
 * a failure either. See the pipeline-window comment below.
 *
 * The comparison is on `raw`, the JSON literal, which is exactly the text that
 * was POSTed, so `1.0` vs `1` cannot be read as a revert. Leading/trailing
 * space is ignored; nothing else is normalised, because normalising is how a
 * check stops being able to fail. */
/* HOW LONG TO WAIT BEFORE CALLING A WRITE LOST -- AND WHY A CLOCK CANNOT
 * ANSWER THAT QUESTION.
 *
 * The previous rule here was a wall clock: 10 x 800 ms = 8 s, derived from ONE
 * `cSbPeriodMs = 5000` collect+push cycle in
 * `host/Aowlspt.Host.Il2Cpp/settingsbridge.nim`. That derivation was short by a
 * whole cycle, and MEASURED to be short: on a live client an edit POSTed at
 * t+0.0 s was applied by the host at t+6.2 s and only became visible on
 * `GET /aowlspt/settings/<guid>` at t+13.7 s -- because `sbCollect()` snapshots
 * the rows BEFORE the sync whose reply carries the edit, so the push that
 * DRAINS an edit still carries the PRE-edit rows and the new value first
 * appears on the push after that. Two pushes, not one. The 8 s budget expired
 * in between every time, and the panel showed NOT APPLIED for an edit the host
 * log recorded as applied. A check that goes red on the working path is the
 * same disease as one that cannot go red at all.
 *
 * So the wait is no longer timed against a clock. It is gated on OBSERVED
 * PIPELINE PROGRESS, read from `GET /aowlspt/settings/client/status/<guid>
 * ?key=<key>` (settingshub, read-only): the verdict window opens only once the
 * edit has left the queue (`pending == false`) AND this guid has republished
 * its page at least twice since the POST (`pushes >= pushes0 + 2`). Only inside
 * that window can a mismatch mean anything -- and inside it, it means the value
 * genuinely did not stick.
 *
 * The clock survives only as a CAP, so a dead pipeline cannot hang the worker
 * for ever -- and when the cap is what stops the loop the verdict is
 * INCONCLUSIVE, naming the stage it was stuck at. It is never NOT APPLIED,
 * because "I ran out of patience" is not evidence about the value.
 * 40 x 800 ms = 32 s is ~2x the measured 13.7 s worst case; the working path
 * never reaches it, since the loop returns the moment the row matches. */
#define AOWL_OV_VERIFY_TRIES 40
#define AOWL_OV_VERIFY_WAIT  800
/* The wait is served in slices, pumping the POST write leg between them --
 * see `aowl_ov_pump_post`. 100 ms divides 800 exactly, so the wall-clock
 * budget above is unchanged; it just stops being a starvation window. */
#define AOWL_OV_VERIFY_SLICE 100
/* A page nobody has ever pushed as a CLIENT page is server-side (or the
 * panel's own generated one): its store is authoritative the instant the POST
 * returns, so no window has to open and a verdict is available at once. */
#define AOWL_OV_VERIFY_LOCAL_TRIES 3
/* Republishes of this guid that must be observed after the POST before a
 * mismatch can be believed. MEASURED above: the draining push is still stale. */
#define AOWL_OV_VERIFY_PUSHES 2

/* One read of the pipeline stage for (guid, key). Returns 1 when the status
 * route answered in the expected shape and the out-params are meaningful, 0
 * when it did not answer at all (an older backend, or the hub not loaded) --
 * in which case the caller must NOT invent progress. Clobbers `buf`, so the
 * caller re-loads the page afterwards. */
static int32_t aowl_ov_settings_stage(const char* guid, const char* key,
                                      char* buf, int32_t cap,
                                      int32_t* known, int32_t* pending,
                                      int32_t* pushes) {
    wchar_t path[288];
    wchar_t wg[96];
    wchar_t wk[96];
    const char* end;
    const char* v;
    int32_t i = 0, rc;
    *known = 0; *pending = 0; *pushes = 0;
    for (; guid && guid[i] && i < 95; i++) wg[i] = (wchar_t)(unsigned char)guid[i];
    wg[i] = 0;
    for (i = 0; key && key[i] && i < 95; i++) wk[i] = (wchar_t)(unsigned char)key[i];
    wk[i] = 0;
    _snwprintf(path, 288, L"/aowlspt/settings/client/status/%ls?key=%ls", wg, wk);
    path[287] = 0;
    rc = aowl_ov_fetch(L"GET", path, NULL, buf, cap);
    if (rc <= 0 || !aowl_ov_jwhole(buf, rc)) return 0;
    end = buf + rc;
    v = aowl_ov_jmem(buf, end, "known");
    if (!v) return 0;                   /* answered, but not with this shape */
    *known = aowl_ov_jbool(v, end, 0);
    v = aowl_ov_jmem(buf, end, "pending");
    *pending = v ? aowl_ov_jbool(v, end, 0) : 0;
    v = aowl_ov_jmem(buf, end, "pushes");
    *pushes = v ? aowl_ov_jint(v, end, 0) : 0;
    return 1;
}

/* Does the row for `key` read back exactly what was `sent`? Sets `*found` and
 * points `*last` at what it actually reads. The comparison is on `raw`, the
 * JSON literal, so `1.0` vs `1` cannot be read as a revert; leading space is
 * ignored and NOTHING else is normalised, because normalising is how a check
 * stops being able to fail. Called under the same lock discipline as before. */
static int32_t aowl_ov_verify_match(const char* key, const char* sent,
                                    int32_t* found, const char** last) {
    int32_t i;
    const char* a;
    const char* b;
    *found = 0;
    for (i = 0; i < g_ov.itemCount; i++) {
        if (strcmp(g_ov.items[i].key, key) != 0) continue;
        *found = 1;
        /* `auth`, NOT `raw`. `raw` may be carrying the optimistic overlay --
         * the very value `sent` holds -- and comparing it here would make this
         * function incapable of returning 0. `auth` is written only from the
         * served document, so this comparison can still fail, which is the
         * only reason it is worth making. */
        a = g_ov.items[i].auth;
        b = sent ? sent : "";
        while (*a == ' ') a++;
        while (*b == ' ') b++;
        *last = a;
        return strcmp(a, b) == 0;
    }
    return 0;
}

static void aowl_ov_settings_verify(const char* guid, const char* key,
                                    const char* sent, int32_t isMod,
                                    char* buf, int32_t cap) {
    int32_t try_;
    int32_t found = 0;
    int32_t haveStage = 0, known = 0, pending = 0, pushes = 0;
    int32_t pushes0 = -1;               /* republish count before any wait */
    int32_t sawPending = 0;             /* observed still queued */
    int32_t drained = 0;                /* ...and then observed gone */
    int32_t windowOpen = 0;
    int32_t tries = AOWL_OV_VERIFY_TRIES;
    const char* last = "";
    if (!key || !key[0]) { g_ov.writeWhy[0] = 0; aowl_ov_pend_clear(); return; }
    for (try_ = 0; try_ < tries; try_++) {
        /* 1. THE FINISHED STATE. What the row reads NOW against what was sent
         *    -- never the status code (200 on the silent-revert path and the
         *    working one alike, fact #135), never our own request. A match
         *    settles it on either transport and needs no window. */
        if (aowl_ov_verify_match(key, sent, &found, &last)) {
            g_ov.writeWhy[0] = 0;
            aowl_ov_pend_settle(key, AOWL_OV_PEND_NONE);   /* APPLIED */
            return;
        }
        /* 2. WHERE IS IT? Read the stage instead of guessing from a clock. */
        haveStage = aowl_ov_settings_stage(guid, key, buf, cap,
                                           &known, &pending, &pushes);
        if (haveStage) {
            if (!known) {
                windowOpen = 1;
                if (tries > AOWL_OV_VERIFY_LOCAL_TRIES)
                    tries = AOWL_OV_VERIFY_LOCAL_TRIES;
            } else {
                if (pushes0 < 0) pushes0 = pushes;
                if (pending) { sawPending = 1; drained = 0; }
                else if (sawPending) drained = 1;
                if (!pending && pushes >= pushes0 + AOWL_OV_VERIFY_PUSHES)
                    windowOpen = 1;
            }
        } else {
            /* NO STATUS ROUTE: nothing here can prove progress, so nothing
             * here may produce a NOT APPLIED. A match is still a pass; the cap
             * still ends the loop -- as INCONCLUSIVE. */
            windowOpen = 0;
        }
        if (windowOpen) break;
        if (try_ + 1 < tries) {
            /* NOT a bare Sleep. The progress this loop is waiting for --
             * `pushes` going up -- is produced by the settings bridge's
             * `client/sync` POST, and the ONLY thread that sends that POST is
             * this one. Sleeping through the wait starves the write leg for
             * the whole 32 s cap, which is a deadlock the cap merely hides
             * (and which made the bridge fault its push away at 12 s). Pump
             * it in AOWL_OV_VERIFY_SLICE slices instead: the loop still waits
             * AOWL_OV_VERIFY_WAIT of wall clock, but the pipeline it is
             * watching keeps running underneath it. */
            int32_t slept = 0;
            for (; slept < AOWL_OV_VERIFY_WAIT; slept += AOWL_OV_VERIFY_SLICE) {
                aowl_ov_pump_post();
                Sleep(AOWL_OV_VERIFY_SLICE);
            }
            aowl_ov_settings_load(guid, isMod, buf, cap);
        }
    }
    /* 3. Inside an open window, re-read once more, then give a real verdict. */
    if (windowOpen) {
        aowl_ov_settings_load(guid, isMod, buf, cap);
        if (aowl_ov_verify_match(key, sent, &found, &last)) {
            g_ov.writeWhy[0] = 0;
            aowl_ov_pend_settle(key, AOWL_OV_PEND_NONE);   /* APPLIED */
            return;
        }
        if (found)
            aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                        "NOT APPLIED: %s was set to %s and reads back %s. The "
                        "edit reached the owning process and its page has been "
                        "republished since, so this IS the finished state, not "
                        "a delay. This edit is NOT saved.",
                        key, (sent && sent[0]) ? sent : "(nothing)",
                        last[0] ? last : "(nothing)");
        else
            aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                        "INCONCLUSIVE: %s was written and %s has republished "
                        "since, but the re-read does not contain that row, so "
                        "whether it took is unknown.",
                        key, guid ? guid : "the page");
    } else if (!haveStage) {
        aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                    "INCONCLUSIVE: %s was written, but this backend has no "
                    "client/status route, so a value that did not take cannot "
                    "be told from one still in flight. It reads back %s after "
                    "%d s.",
                    key, last[0] ? last : "(nothing)",
                    (tries * AOWL_OV_VERIFY_WAIT) / 1000);
    } else if (sawPending && !drained) {
        aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                    "INCONCLUSIVE: %s is still QUEUED for the game process "
                    "after %d s -- the settings bridge has not collected it. "
                    "The edit is not lost; nothing has applied it yet.",
                    key, (tries * AOWL_OV_VERIFY_WAIT) / 1000);
    } else {
        aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                    "INCONCLUSIVE: %s left the queue, but %s has republished "
                    "only %d of the %d times needed to show the result, after "
                    "%d s. It reads back %s -- that is the OLD value, not a "
                    "verdict.",
                    key, guid ? guid : "the page",
                    pushes0 >= 0 ? pushes - pushes0 : 0,
                    AOWL_OV_VERIFY_PUSHES,
                    (tries * AOWL_OV_VERIFY_WAIT) / 1000,
                    last[0] ? last : "(nothing)");
    }
    aowl_ov_note(g_ov.writeWhy);
    /* The verdict, onto the row. NOT APPLIED is the only REJECTED case: it is
     * the only branch above that has proof the pipeline finished. Every other
     * branch is INCONCLUSIVE and must say so rather than borrowing REJECTED`s
     * certainty -- "I could not look" is not a failure verdict either. */
    aowl_ov_pend_settle(key, windowOpen && found ? AOWL_OV_PEND_REJECTED
                                                 : AOWL_OV_PEND_UNKNOWN);
}

static void aowl_ov_settings_set(const AowlOvCmd* cmd, char* buf, int32_t cap) {
    wchar_t path[224];
    wchar_t warg[96];
    char jbody[256];
    int32_t i = 0;
    for (; cmd->guid[i] && i < 95; i++) warg[i] = (wchar_t)(unsigned char)cmd->guid[i];
    warg[i] = 0;
    /* BEFORE either write leg, so the re-GET each one performs is already
     * overlaid and the player`s value never leaves the screen. */
    (void)aowl_ov_pend_begin(cmd->guid, cmd->skey, cmd->sval);
    if (!strcmp(cmd->guid, AOWL_OV_PANEL_PAGE)) {
        /* Applied locally and re-generated, which is the same shape the HTTP
         * path has: write, then RE-READ, so the row shows what was actually
         * kept rather than what was hoped for. A refused value therefore snaps
         * back on screen instead of being displayed as if it took. */
        (void)aowl_ov_panel_set(cmd->skey, cmd->sval);
        aowl_ov_settings_load(cmd->guid, 1, buf, cap);
        /* The panel's own page is generated in-process, so one look settles
         * it: `isMod` is irrelevant and no retry can change the answer. */
        aowl_ov_settings_verify(cmd->guid, cmd->skey, cmd->sval, 1, buf, cap);
        return;
    }
    _snwprintf(path, 224, L"/aowlspt/settings/%ls", warg);
    path[223] = 0;
    aowl_ov_fmt(jbody, (int32_t)sizeof(jbody), "{\"key\":\"%s\",\"value\":%s}",
                cmd->skey, cmd->sval);
    (void)aowl_ov_fetch(L"POST", path, jbody, buf, cap);
    /* Tell the settings bridge NOW rather than letting it find out on its own
     * five-second schedule. Set after the POST, so the edit is already queued
     * at settingshub by the time the host tick collects. */
    InterlockedExchange(&g_ov.editKick, 1);
    aowl_ov_settings_load(cmd->guid, 1, buf, cap);
    aowl_ov_settings_verify(cmd->guid, cmd->skey, cmd->sval, 1, buf, cap);
}

/* ================================================================== *
 * The logs screen -- reading the files
 *
 * Everything in this section runs on the WORKER thread except where the
 * comment says otherwise. Nothing here ever runs from `aowl_ov_build`.
 * ================================================================== */

/* Both logs live next to this DLL: `aowlhost.nim` opens `aowlspt-host.log` at
 * `modhost.ownDirectory()`, and `aowlspt-launch.exe` puts the backend and its
 * log in the same install root. So the path is derived from THIS MODULE rather
 * than from a configured directory, a CWD (which the game changes) or an
 * argument the host would have to remember to pass -- one fewer thing that can
 * be wired up wrong and fail silently.
 *
 * If it cannot be derived, both sources say so and neither is retried. */
static void aowl_ov_log_paths(void) {
    char self[300];
    HMODULE mod = NULL;
    DWORD n;
    int32_t i;
    if (g_ov.logPathsDone) return;
    g_ov.logPathsDone = 1;
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCSTR)(void*)&aowl_ov_log_paths, &mod) || !mod) {
        for (i = 0; i < AOWL_LOG_SRCS; i++) {
            g_ov.logOff2[i] = 1;
            aowl_ov_copy(g_ov.logWhy[i], (int32_t)sizeof(g_ov.logWhy[i]),
                         "cannot find this module, so the install directory is unknown");
        }
        return;
    }
    n = GetModuleFileNameA(mod, self, (DWORD)sizeof(self));
    if (n == 0 || n >= sizeof(self)) {
        for (i = 0; i < AOWL_LOG_SRCS; i++) {
            g_ov.logOff2[i] = 1;
            aowl_ov_copy(g_ov.logWhy[i], (int32_t)sizeof(g_ov.logWhy[i]),
                         "GetModuleFileName did not give a usable path");
        }
        return;
    }
    while (n > 0 && self[n - 1] != '\\' && self[n - 1] != '/') n--;
    self[n] = 0;
    _snprintf(g_ov.logPath[AOWL_LOG_SERVER],
              sizeof(g_ov.logPath[0]) - 1, "%saowlspt-backend.log", self);
    _snprintf(g_ov.logPath[AOWL_LOG_CLIENT],
              sizeof(g_ov.logPath[0]) - 1, "%saowlspt-host.log", self);
    g_ov.logPath[AOWL_LOG_SERVER][sizeof(g_ov.logPath[0]) - 1] = 0;
    g_ov.logPath[AOWL_LOG_CLIENT][sizeof(g_ov.logPath[0]) - 1] = 0;
}

/* The level word, as written. Anything else is UNKNOWN -- never info. */
static int32_t aowl_ov_log_lvl(const char* w, int32_t n) {
    if (n == 2 && strncmp(w, "ok", 2) == 0) return AOWL_LOGLVL_OK;
    if (n == 4 && strncmp(w, "info", 4) == 0) return AOWL_LOGLVL_INFO;
    if (n == 4 && strncmp(w, "warn", 4) == 0) return AOWL_LOGLVL_WARN;
    if (n == 5 && strncmp(w, "error", 5) == 0) return AOWL_LOGLVL_ERR;
    if (n == 4 && strncmp(w, "fail", 4) == 0) return AOWL_LOGLVL_ERR;
    return AOWL_LOGLVL_UNKNOWN;
}

static const char* aowl_ov_log_lvl_name(int32_t l) {
    if (l == AOWL_LOGLVL_OK) return "ok";
    if (l == AOWL_LOGLVL_INFO) return "info";
    if (l == AOWL_LOGLVL_WARN) return "warn";
    if (l == AOWL_LOGLVL_ERR) return "error";
    return "?";
}

static uint32_t aowl_ov_log_lvl_col(int32_t l) {
    if (l == AOWL_LOGLVL_OK) return AOWL_OV_GOOD;
    if (l == AOWL_LOGLVL_WARN) return AOWL_OV_WARN;
    if (l == AOWL_LOGLVL_ERR) return AOWL_OV_ERR;
    if (l == AOWL_LOGLVL_INFO) return AOWL_OV_TEXT;
    return AOWL_OV_DIM;   /* `?` is dim, not white: it is not an info line */
}

/* Interns a facet name and returns its index, or AOWL_LOG_FACET_SYSTEM. Called
 * with `cs` held. The table never shrinks and never reorders, which is what
 * lets `logFacetFilt` be a plain index that survives an append. */
static int32_t aowl_ov_log_intern(const char* name, int32_t n) {
    int32_t i, k;
    char low[AOWL_OV_LOG_FACETLEN];
    if (n <= 0 || n >= AOWL_OV_LOG_FACETLEN) return AOWL_LOG_FACET_SYSTEM;
    for (k = 0; k < n; k++) {
        char c = name[k];
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
        low[k] = c;
    }
    low[n] = 0;
    for (i = 0; i < g_ov.logFacetN; i++)
        if (strcmp(g_ov.logFacets[i], low) == 0) return i;
    if (g_ov.logFacetN >= AOWL_OV_LOG_FACETS) {
        /* Counted, not dropped in silence -- the strip prints it. */
        g_ov.logFacetOver++;
        return AOWL_LOG_FACET_SYSTEM;
    }
    aowl_ov_copy(g_ov.logFacets[g_ov.logFacetN], AOWL_OV_LOG_FACETLEN, low);
    return g_ov.logFacetN++;
}

/* THE FACET RULE. Stated in full where the screen is described; this is it in
 * code, and it is deliberately the whole of it -- there is no table of mod
 * names to fall back on, because a hardcoded table is wrong the day a mod is
 * added, and wrong silently. */
static int32_t aowl_ov_log_facet(const char* msg, int32_t n) {
    int32_t i = 0, hasAlpha = 0;
    while (i < n && msg[i] != ' ' && msg[i] != '\t') {
        char c = msg[i];
        if (c == ':') break;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) hasAlpha = 1;
        else if (!((c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
            return AOWL_LOG_FACET_SYSTEM;
        i++;
        if (i >= AOWL_OV_LOG_FACETLEN) return AOWL_LOG_FACET_SYSTEM;
    }
    /* The colon is REQUIRED and must be the token's last character: `sain:` is
     * a facet, `sain` is not, and neither is `http://x`. */
    if (i < 2 || i >= n || msg[i] != ':') return AOWL_LOG_FACET_SYSTEM;
    if (i + 1 < n && msg[i + 1] != ' ' && msg[i + 1] != '\t')
        return AOWL_LOG_FACET_SYSTEM;
    if (!hasAlpha) return AOWL_LOG_FACET_SYSTEM;
    return aowl_ov_log_intern(msg, i);
}

/* One line into the ring. Called with `cs` held. `n` excludes the terminator;
 * a longer line is kept up to the buffer and marked `..`, never dropped -- a
 * 6 KB PROBE line still has a readable first 190 characters, and its facet and
 * level are both inside them. */
static void aowl_ov_log_append(int32_t src, const char* line, int32_t n) {
    AowlOvLogLine* L;
    int32_t i, cut = 0, msgAt = 0;
    while (n > 0 && (line[n - 1] == 13 || line[n - 1] == 10)) n--;
    if (n <= 0) return;
    L = &g_ov.logs[g_ov.logSeq % AOWL_OV_LOG_MAX];
    if (n > AOWL_OV_LOG_TEXT - 3) { n = AOWL_OV_LOG_TEXT - 3; cut = 1; }
    memcpy(L->text, line, (size_t)n);
    if (cut) { L->text[n] = '.'; L->text[n + 1] = '.'; n += 2; }
    L->text[n] = 0;
    L->src = src;
    L->lvl = AOWL_LOGLVL_UNKNOWN;
    L->facet = AOWL_LOG_FACET_SYSTEM;
    L->msgAt = 0;
    /* `[0:00:01.187] ok     admin diag (...)`. No prefix is a real case (a
     * wrapped message, a stack trace) and it keeps `?` and `system`, because
     * inheriting the line above would be a guess dressed as a fact. */
    if (L->text[0] == '[') {
        for (i = 1; i < n && L->text[i] != ']'; i++) { }
        if (i < n) {
            int32_t j = i + 1, w;
            while (j < n && (L->text[j] == ' ' || L->text[j] == '\t')) j++;
            w = j;
            while (w < n && L->text[w] != ' ' && L->text[w] != '\t') w++;
            L->lvl = aowl_ov_log_lvl(L->text + j, w - j);
            if (L->lvl != AOWL_LOGLVL_UNKNOWN) {
                while (w < n && (L->text[w] == ' ' || L->text[w] == '\t')) w++;
                msgAt = w;
            } else {
                msgAt = j;   /* an unrecognised level word IS the message */
            }
        }
    }
    L->msgAt = msgAt;
    if (msgAt < n)
        L->facet = aowl_ov_log_facet(L->text + msgAt, n - msgAt);
    g_ov.logSeq++;
    if (g_ov.logCount < AOWL_OV_LOG_MAX) g_ov.logCount++;
    else g_ov.logDropped++;
    g_ov.logLines[src]++;
    g_ov.logSerial++;
}

/* One source, one poll. Opens, reads at most AOWL_OV_LOG_CHUNK new bytes, and
 * appends whole lines. The file IO happens with `cs` NOT held; only the append
 * loop takes it.
 *
 * The share mode is the point: the backend has its log open for append and the
 * host has the other one, so anything less than FILE_SHARE_READ | WRITE |
 * DELETE fails on a live install -- which is the only install there is. */
static void aowl_ov_log_pull(int32_t src, char* scratch, int32_t cap) {
    HANDLE h;
    LARGE_INTEGER sz, pos;
    DWORD got = 0;
    int32_t want, i, start;

    if (g_ov.logOff2[src] || !g_ov.logPath[src][0]) return;
    h = CreateFileA(g_ov.logPath[src], GENERIC_READ,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        DWORD e = GetLastError();
        g_ov.logFail[src]++;
        aowl_ov_fmt(g_ov.logWhy[src], (int32_t)sizeof(g_ov.logWhy[0]),
                    "cannot open %s (error %lu)", g_ov.logPath[src],
                    (unsigned long)e);
        if (g_ov.logFail[src] >= AOWL_OV_LOG_MAXFAIL) {
            g_ov.logOff2[src] = 1;
            aowl_ov_fmt(g_ov.logWhy[src], (int32_t)sizeof(g_ov.logWhy[0]),
                        "gave up after %d failures to open %s (error %lu)",
                        AOWL_OV_LOG_MAXFAIL, g_ov.logPath[src],
                        (unsigned long)e);
        }
        return;
    }
    if (!GetFileSizeEx(h, &sz)) {
        CloseHandle(h);
        g_ov.logFail[src]++;
        aowl_ov_copy(g_ov.logWhy[src], (int32_t)sizeof(g_ov.logWhy[0]),
                     "the file opened but its size could not be read");
        return;
    }
    g_ov.logFail[src] = 0;
    /* Truncated or rotated: start again from the tail rather than reading from
     * an offset past the end, which would look like "the log went quiet". */
    if (sz.QuadPart < g_ov.logOff[src]) {
        g_ov.logOff[src] = 0;
        g_ov.logOpened[src] = 0;
        g_ov.logCarryN[src] = 0;
    }
    if (!g_ov.logOpened[src]) {
        g_ov.logOpened[src] = 1;
        g_ov.logOff[src] = sz.QuadPart > (long long)AOWL_OV_LOG_TAIL
                         ? sz.QuadPart - (long long)AOWL_OV_LOG_TAIL : 0;
        /* A tail that starts mid-line drops that half-line rather than showing
         * it: half a line at the very top reads as a corrupted log. */
        g_ov.logCarryN[src] = g_ov.logOff[src] > 0 ? -1 : 0;
    }
    if (sz.QuadPart <= g_ov.logOff[src]) {
        CloseHandle(h);
        if (g_ov.logLines[src] == 0)
            aowl_ov_fmt(g_ov.logWhy[src], (int32_t)sizeof(g_ov.logWhy[0]),
                        "%s is %lld bytes and nothing new has been written",
                        g_ov.logPath[src], (long long)sz.QuadPart);
        return;
    }
    want = (int32_t)(sz.QuadPart - g_ov.logOff[src]);
    if (want > cap) want = cap;
    if (want > AOWL_OV_LOG_CHUNK) want = AOWL_OV_LOG_CHUNK;
    pos.QuadPart = g_ov.logOff[src];
    if (!SetFilePointerEx(h, pos, NULL, FILE_BEGIN) ||
        !ReadFile(h, scratch, (DWORD)want, &got, NULL)) {
        CloseHandle(h);
        g_ov.logFail[src]++;
        aowl_ov_copy(g_ov.logWhy[src], (int32_t)sizeof(g_ov.logWhy[0]),
                     "the file opened but the read failed");
        return;
    }
    CloseHandle(h);
    if (got == 0) return;
    g_ov.logOff[src] += (long long)got;
    g_ov.logWhy[src][0] = 0;

    EnterCriticalSection(&g_ov.cs);
    start = 0;
    for (i = 0; i < (int32_t)got; i++) {
        if (scratch[i] != 10) continue;
        if (g_ov.logCarryN[src] < 0) {
            g_ov.logCarryN[src] = 0;      /* the first-read half-line, dropped */
        } else if (g_ov.logCarryN[src] > 0) {
            int32_t room = AOWL_OV_LOG_TEXT - 1 - g_ov.logCarryN[src];
            int32_t take = i - start;
            if (take > room) take = room;
            if (take > 0)
                memcpy(g_ov.logCarry[src] + g_ov.logCarryN[src],
                       scratch + start, (size_t)take);
            aowl_ov_log_append(src, g_ov.logCarry[src],
                               g_ov.logCarryN[src] + take);
            g_ov.logCarryN[src] = 0;
        } else {
            aowl_ov_log_append(src, scratch + start, i - start);
        }
        start = i + 1;
    }
    /* Whatever is left has no newline yet -- carry it, bounded. A single line
     * longer than the carry buffer is cut here and marked by the append, the
     * same treatment a 6 KB PROBE line gets. */
    if (g_ov.logCarryN[src] >= 0) {
        int32_t rest = (int32_t)got - start;
        if (rest > AOWL_OV_LOG_TEXT - 1) rest = AOWL_OV_LOG_TEXT - 1;
        if (rest > 0) {
            memcpy(g_ov.logCarry[src], scratch + start, (size_t)rest);
            g_ov.logCarryN[src] = rest;
        }
    }
    LeaveCriticalSection(&g_ov.cs);
}

static DWORD WINAPI aowl_ov_worker(LPVOID unused) {
    /* Static rather than automatic: 32 KB on a thread stack is affordable and
     * 32 KB that is allocated once is one fewer thing that can fail late.
     * `/aowlspt/mods/lists` on the shipped registry is about 2 KB; the ceiling
     * is what a very large registry could produce, and a body that does not fit
     * is truncated, fails to parse into rows, and leaves the tables alone.
     *
     * It was 32,768 bytes and that was the whole of defect (1): MEASURED with
     * curl against the live backend, `GET /aowlspt/settings/aowl.tarkov` with
     * `Accept-Encoding: identity` answers 200 with **283,798 bytes** (802
     * rows), and `GET /aowlspt/settings/aowl.sain` answers 1,156 (5 rows). The
     * small page loaded and the large one did not, and the panel said "the mod
     * may not be loaded" about a mod that was loaded and answering. The cap is
     * the only thing that was ever wrong. See `AOWL_OV_HTTP_BUF`. */
    static char buf[AOWL_OV_HTTP_BUF];
    (void)unused;
    /* Starts at the interval so the first poll happens immediately: an overlay
     * that shows a stale read-only list for a second after the game starts
     * looks broken. */
    int32_t sinceFast = 1000;
    int32_t sinceSlow = 3000;
    /* How long to wait between tries while nothing is answering. Doubles on
     * each failure up to four seconds and resets the moment one succeeds. */
    int32_t backoff = 250;
    /* Set once a probe has actually come back empty-handed. Distinct from
     * `!backendOk`, which is also true for the first quarter-second of the
     * process's life when nothing has been tried yet. */
    int32_t probeFailed = 0;
    /* The feed starts at zero rather than at its interval: the host asks for it
     * a moment after the worker exists, and a first fetch fired before
     * `aowl_ov_sync_start` has run would only have to be thrown away. */
    int32_t sinceSync = 0;
    /* Starts at the interval so the first frame of the logs screen is not a
     * blank pane for four hundred milliseconds. */
    int32_t sinceLog = AOWL_OV_LOG_POLL_MS;

    while (g_ov.workerRun) {
        AowlOvCmd cmd;
        int32_t have = 0;
        EnterCriticalSection(&g_ov.cs);
        if (g_ov.cmdCount > 0) {
            cmd = g_ov.cmds[0];
            for (int32_t i = 1; i < g_ov.cmdCount; i++) g_ov.cmds[i - 1] = g_ov.cmds[i];
            g_ov.cmdCount--;
            have = 1;
        }
        LeaveCriticalSection(&g_ov.cs);

        /* --- a gesture made while the backend is gone -------------------
         *
         * Refused here, on the spot, rather than sent. A fetch against a dead
         * port costs a measured two seconds inside WinHTTP that no timeout
         * shortens (see `aowl_ov_http`), so a queue of them is a queue that
         * drains at one gesture every two seconds -- and the first version of
         * this loop did exactly that: three keypresses were still queued five
         * seconds after they were made, with the panel drawing happily at full
         * rate and saying nothing about it.
         *
         * The queue is emptied rather than held, and the player is told. "I
         * cannot reach the backend, so I did not do it" is a better answer than
         * a row that sits at `~` for a minute, and it is the same answer they
         * would get eventually anyway.
         *
         * `probeFailed` rather than `!backendOk`: at start-up nothing has
         * answered yet either, and a keypress in the first quarter-second must
         * be sent rather than refused. */
        if (have && probeFailed) {
            EnterCriticalSection(&g_ov.cs);
            g_ov.cmdCount = 0;
            g_ov.resultCount = 0;
            aowl_ov_copy(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat),
                         "not sent: the backend is unreachable");
            aowl_ov_copy(g_ov.lastError, (int32_t)sizeof(g_ov.lastError),
                         "the backend is not answering, so nothing was sent and "
                         "nothing was changed. The panel is showing the last "
                         "thing it heard.");
            for (int32_t i = 0; i < g_ov.modCount; i++) g_ov.mods[i].pending = 0;
            LeaveCriticalSection(&g_ov.cs);
            g_ov.dataSerial++;
            have = 0;
        }

        /* Settings-mode commands are their own shape -- a page load or a
         * single-row POST -- and are handled before the mod-control path so the
         * reply parsing below never sees them. */
        if (have && cmd.kind == AOWL_CMD_SPAGE) {
            aowl_ov_settings_load(cmd.guid, cmd.enabled, buf, (int32_t)sizeof(buf));
            have = 0;
        } else if (have && cmd.kind == AOWL_CMD_SSET) {
            aowl_ov_settings_set(&cmd, buf, (int32_t)sizeof(buf));
            have = 0;
        }

        /* Commands first: a keypress should not wait out the poll interval. */
        if (have) {
            wchar_t path[224];
            wchar_t warg[96];
            char what[96];
            const wchar_t* verb = L"GET";
            const char* postBody = NULL;
            char jbody[48];
            int32_t rc;
            int32_t i = 0;
            for (; cmd.guid[i] && i < 95; i++) warg[i] = (wchar_t)(unsigned char)cmd.guid[i];
            warg[i] = 0;

            if (cmd.kind == AOWL_CMD_TOGGLE) {
                /* `mods/manager` serves this: it sets the override, re-resolves,
                 * and then asks the host to make it true, all in the one
                 * request -- so the reply carries both the new row and the
                 * per-mod outcome of trying. */
                _snwprintf(path, 224, L"/aowlspt/mods/toggle/%ls", warg);
                aowl_ov_fmt(jbody, (int32_t)sizeof(jbody), "{\"enabled\":%s}",
                            cmd.enabled ? "true" : "false");
                postBody = jbody;
                verb = L"POST";
                aowl_ov_fmt(what, (int32_t)sizeof(what), "%s %s",
                            cmd.enabled ? "enable" : "disable", cmd.guid);
            } else if (cmd.kind == AOWL_CMD_CLEAR) {
                _snwprintf(path, 224, L"/aowlspt/mods/clear/%ls", warg);
                aowl_ov_fmt(what, (int32_t)sizeof(what), "clear override on %s",
                            cmd.guid);
            } else if (cmd.kind == AOWL_CMD_SELECT) {
                _snwprintf(path, 224, L"/aowlspt/mods/select/%ls", warg);
                aowl_ov_fmt(what, (int32_t)sizeof(what), "select list %s", cmd.guid);
            } else if (cmd.kind == AOWL_CMD_RELOAD) {
                _snwprintf(path, 224, L"/aowlspt/mods/reload");
                aowl_ov_fmt(what, (int32_t)sizeof(what), "reload the registry");
            } else {
                _snwprintf(path, 224, L"/aowlspt/mods/apply");
                aowl_ov_fmt(what, (int32_t)sizeof(what), "apply the selection");
            }
            /* The one `_snwprintf` that ran above, terminated here for all
             * five. `what` is `aowl_ov_fmt`'s now and terminates itself. */
            path[223] = 0;

            rc = aowl_ov_fetch(verb, path, postBody, buf, (int32_t)sizeof(buf));
            if (rc > 0) {
                aowl_ov_read_reply(buf, rc, what);
            } else {
                /* The gesture is reported as failed rather than left looking
                 * pending, and the row's `~` stays up until a poll says
                 * otherwise -- which is the truth: nothing is known to have
                 * changed. */
                EnterCriticalSection(&g_ov.cs);
                g_ov.resultCount = 0;
                aowl_ov_copy(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat), what);
                if (!g_ov.lastError[0])
                    aowl_ov_copy(g_ov.lastError, (int32_t)sizeof(g_ov.lastError),
                                 "the backend did not answer, so nothing was changed");
                LeaveCriticalSection(&g_ov.cs);
                g_ov.dataSerial++;
                /* One failure is enough: everything else in the queue is
                 * refused on the spot rather than costing two seconds each. */
                probeFailed = 1;
            }
            if (cmd.kind == AOWL_CMD_TOGGLE && g_ov.toggleFn)
                g_ov.toggleFn(cmd.guid, cmd.enabled, g_ov.toggleUser);
            sinceFast = 1000;   /* force a re-read so the panel shows truth */
            sinceSlow = 3000;
        }

        /* --- when the far end is not there ------------------------------
         *
         * A dead port is not free. Every failed fetch costs its connect and
         * send timeouts, and four routes on a one-second timer means the loop
         * spends most of a second inside WinHTTP -- during which the command a
         * player just queued by pressing SPACE sits untouched. That is exactly
         * what happened the first time this was run against a closed port: the
         * panel stayed interactive and drew at full rate (the render thread
         * never waits on any of this), and three keypresses were still in the
         * queue five seconds later.
         *
         * So while nothing is answering, only `/panel` is tried, and the gap
         * between tries doubles to four seconds. The moment one succeeds the
         * backoff resets and the other three routes are fetched immediately.
         * Commands are never backed off -- a person pressed a key, and one
         * short-timeout attempt is the right answer even when it will fail. */
        if (!g_ov.backendOk) {
            if (sinceFast >= backoff) {
                int32_t rc;
                sinceFast = 0;
                rc = aowl_ov_fetch(L"GET", L"/aowlspt/mods/panel", NULL, buf,
                                   (int32_t)sizeof(buf));
                if (rc > 0) {
                    EnterCriticalSection(&g_ov.cs);
                    aowl_ov_read_panel(buf, rc);
                    LeaveCriticalSection(&g_ov.cs);
                    g_ov.dataSerial++;
                    backoff = 250;
                    probeFailed = 0;
                    sinceFast = 1000;   /* pick the rest up on the next pass */
                    sinceSlow = 3000;
                } else {
                    backoff = backoff < 4000 ? backoff * 2 : 4000;
                    probeFailed = 1;
                }
            }
        } else if (sinceFast >= 1000) {
            int32_t rc;
            sinceFast = 0;
            backoff = 250;
            probeFailed = 0;
            rc = aowl_ov_fetch(L"GET", L"/aowlspt/mods/panel", NULL, buf,
                               (int32_t)sizeof(buf));
            if (rc > 0) {
                EnterCriticalSection(&g_ov.cs);
                aowl_ov_read_panel(buf, rc);
                LeaveCriticalSection(&g_ov.cs);
                g_ov.dataSerial++;
            }
            rc = aowl_ov_fetch(L"GET", L"/aowlspt/mods/list", NULL, buf,
                               (int32_t)sizeof(buf));
            if (rc > 0) {
                EnterCriticalSection(&g_ov.cs);
                aowl_ov_read_list(buf, rc);
                LeaveCriticalSection(&g_ov.cs);
                g_ov.dataSerial++;
            }
        }

        if (g_ov.backendOk && sinceSlow >= 3000) {
            int32_t rc;
            sinceSlow = 0;
            rc = aowl_ov_fetch(L"GET", L"/aowlspt/mods/lists", NULL, buf,
                               (int32_t)sizeof(buf));
            if (rc > 0) {
                EnterCriticalSection(&g_ov.cs);
                aowl_ov_read_lists(buf, rc);
                LeaveCriticalSection(&g_ov.cs);
                g_ov.dataSerial++;
            }
            rc = aowl_ov_fetch(L"GET", L"/aowlspt/mods/conflicts", NULL, buf,
                               (int32_t)sizeof(buf));
            if (rc > 0) {
                EnterCriticalSection(&g_ov.cs);
                aowl_ov_read_conflicts(buf, rc);
                LeaveCriticalSection(&g_ov.cs);
                g_ov.dataSerial++;
            }

            /* The settings nav's real source. Re-fetched every slow pass
             * rather than held, because a mod loaded after start-up publishes
             * settings after start-up, and a nav that was correct once is not
             * the same thing as a nav that is correct. Cheap: the shipped
             * index is a few hundred bytes.
             *
             * A failure leaves the previous nav ALONE and records why, so a
             * momentary backend hiccup does not blank a screen the player is
             * looking at -- but it never substitutes the mod roster. */
            rc = aowl_ov_fetch(L"GET", L"/aowlspt/settings/index", NULL, buf,
                               (int32_t)sizeof(buf));
            EnterCriticalSection(&g_ov.cs);
            if (rc > 0 && (unsigned char)buf[0] != 0x78 &&
                aowl_ov_jwhole(buf, rc) && aowl_ov_jmem(buf, buf + rc, "mods")) {
                aowl_ov_read_settings_index(buf, rc);
            } else if (!g_ov.idxGot) {
                aowl_ov_copy(g_ov.idxWhy, (int32_t)sizeof(g_ov.idxWhy),
                             rc > 0
                               ? "GET /aowlspt/settings/index did not answer with "
                                 "a mods list -- the settings hub (aowl.settingshub) "
                                 "is not loaded, so nothing can enumerate which mods "
                                 "have settings"
                               : "GET /aowlspt/settings/index did not answer");
            }
            LeaveCriticalSection(&g_ov.cs);

            /* --- the launch hint`s own setting, as actually READ ---------
             *
             * `aowl.uihub` declares `launchHint`. It is fetched once, here on
             * the worker, and the value that comes back over the wire is what
             * the toast obeys -- NOT the default this file declares. A default
             * is not a value: a flag that reads false in source and true in the
             * deployed config is the shape that has cost this project launch
             * cycles, so the number is logged as read and the panel`s status
             * line carries it.
             *
             * Until the fetch answers, the prefs file`s remembered value is
             * used, which is what makes the hint honour a player`s choice on
             * the very next launch instead of one launch later. A backend that
             * never answers therefore leaves the hint at whatever the player
             * last chose, not at the source default. */
            if (!g_ov.hintFetched) {
                rc = aowl_ov_fetch(L"GET", L"/aowlspt/settings/aowl.uihub",
                                   NULL, buf, (int32_t)sizeof(buf));
                if (rc > 0 && (unsigned char)buf[0] != 0x78 &&
                    aowl_ov_jwhole(buf, rc)) {
                    const char* end = buf + rc;
                    const char* it;
                    for (it = aowl_ov_jarr(buf, end); it;
                         it = aowl_ov_jnext(it, end)) {
                        char k[48];
                        aowl_ov_jput(it, end, "key", k, (int32_t)sizeof(k));
                        if (strcmp(k, "launchHint") == 0) {
                            const char* v = aowl_ov_jmem(it, end, "value");
                            int32_t was = g_ov.hintEnabled;
                            if (v) g_ov.hintEnabled = aowl_ov_jbool(v, end, 1);
                            g_ov.hintFetched = 1;
                            aowl_ov_fmt(g_ov.hintWhy, (int32_t)sizeof(g_ov.hintWhy),
                                        "launchHint READ from aowl.uihub = %d "
                                        "(prefs file had %d)",
                                        g_ov.hintEnabled, was);
                            aowl_ov_note(g_ov.hintWhy);
                            InterlockedExchange(&g_ov.prefsDirty, 1);
                            break;
                        }
                    }
                }
                if (!g_ov.hintFetched && g_ov.everOk) {
                    /* The backend is up and did not serve the key. Said out
                     * loud: a hint that advertises an off-switch which is not
                     * in the settings surface is worse than no hint, so this
                     * is the line that catches uihub having been built without
                     * its schema. */
                    g_ov.hintFetched = 1;
                    aowl_ov_copy(g_ov.hintWhy, (int32_t)sizeof(g_ov.hintWhy),
                                 "launchHint NOT served by aowl.uihub -- the "
                                 "hint`s off-switch is not in the settings "
                                 "surface; using the remembered value");
                    aowl_ov_note(g_ov.hintWhy);
                }
            }

            /* Geometry the render thread changed. Written HERE, on the worker,
             * because a synchronous file write inside Present is a frame the
             * player feels. */
            if (InterlockedCompareExchange(&g_ov.prefsDirty, 0, 1) == 1)
                aowl_ov_prefs_save();

            /* The settings screen's page index. The SPT surface is a fixed
             * catalogue the hub serves once; a 404 (no hub loaded) just leaves
             * the nav as the mod pages, which is a coherent screen on its own.
             * Re-tried until it answers, then held. */
            if (!g_ov.sptGot) {
                rc = aowl_ov_fetch(L"GET", L"/aowlspt/settings/spt/index", NULL,
                                   buf, (int32_t)sizeof(buf));
                if (rc > 0 && (unsigned char)buf[0] != 0x78 &&
                    aowl_ov_jwhole(buf, rc)) {
                    EnterCriticalSection(&g_ov.cs);
                    aowl_ov_read_spt_index(buf, rc);
                    LeaveCriticalSection(&g_ov.cs);
                }
            }
            /* The nav is mods first, then SPT. Rebuilt here so a mod loaded or
             * unloaded since the last pass, or an index that just arrived, is
             * reflected without the render thread ever touching the mod table. */
            EnterCriticalSection(&g_ov.cs);
            aowl_ov_rebuild_pages();
            LeaveCriticalSection(&g_ov.cs);
            g_ov.dataSerial++;
        }

        /* The mod-sync feed. Its own timer, because it is a different question
         * asked at a different rate: the panel is a view a person is looking at
         * and wants fresh, this is a control loop that changes what is loaded
         * in the process and wants to be unhurried. */
        {
            wchar_t wpath[192];
            int32_t want = 0;
            EnterCriticalSection(&g_ov.cs);
            if (g_ov.syncMs > 0 && sinceSync >= g_ov.syncMs) {
                int32_t i = 0;
                for (; g_ov.syncPath[i] && i < 191; i++)
                    wpath[i] = (wchar_t)(unsigned char)g_ov.syncPath[i];
                wpath[i] = 0;
                want = i > 0;
            }
            LeaveCriticalSection(&g_ov.cs);

            if (want) {
                int32_t rc;
                sinceSync = 0;
                rc = aowl_ov_http(L"GET", wpath, NULL, buf, (int32_t)sizeof(buf));
                /* Bumped for THIS fetch regardless of outcome -- it answers
                 * "has the worker gotten to my path at all", not "did it
                 * succeed". `sync_start` never resets it, so a caller diffs
                 * against the value it read right after arming. */
                EnterCriticalSection(&g_ov.cs);
                g_ov.syncAttempts++;
                LeaveCriticalSection(&g_ov.cs);
                /* Published only when there is a whole plausible body. A
                 * failure, an empty answer or a deflated one leaves the
                 * previous serial alone, so the host does exactly what it was
                 * already doing -- which for a control loop over loaded code is
                 * the only safe thing a transport error can mean. */
                if (rc > 0 && (unsigned char)buf[0] != 0x78 &&
                    rc < AOWL_OV_SYNC_MAX) {
                    EnterCriticalSection(&g_ov.cs);
                    memcpy(g_ov.syncBody, buf, (size_t)rc);
                    g_ov.syncBody[rc] = 0;
                    g_ov.syncLen = rc;
                    g_ov.syncSerial++;
                    LeaveCriticalSection(&g_ov.cs);
                } else if (rc > 0) {
                    /* A WHOLE, CORRECT BODY CAN LAND HERE. Recorded rather
                     * than dropped into silence -- this branch is what made
                     * a 569,247-byte `/aowlspt/settings/index/full` look
                     * like an unimplemented route for a whole session. */
                    EnterCriticalSection(&g_ov.cs);
                    g_ov.syncDrops++;
                    g_ov.syncDropLen = rc;
                    g_ov.syncDropZlib = ((unsigned char)buf[0] == 0x78);
                    LeaveCriticalSection(&g_ov.cs);
                }
            }
        }

        /* The write leg. One armed request per pass, same worker, same
         * `aowl_ov_http` machinery the GET feed and `aowl_ov_fetch` both use --
         * no second WinHTTP path. Read the armed path+body out under the lock,
         * send with the lock released (a two-second WinHTTP call must never
         * hold `cs`), then publish the outcome under the lock again. Always
         * published, success or failure: unlike the GET feed, a write's
         * failure is not "keep showing the old value", it is something the
         * caller must be told so it does not believe an edit stuck. */
        aowl_ov_pump_post();

        /* --- THE LOG TAIL ------------------------------------------------
         *
         * Only while the screen is being drawn (`logWant`), and at most once
         * every AOWL_OV_LOG_POLL_MS. Two opens, two reads of at most
         * AOWL_OV_LOG_CHUNK bytes each, on this thread; the render thread does
         * none of it. With the screen shut this block is one integer compare
         * per pass and touches no file at all -- which is the whole reason
         * `logWant` exists rather than polling unconditionally.
         *
         * `buf` is reused: every step above fills it before reading it, so
         * nothing here can be seen by them. */
        if (g_ov.logWant && sinceLog >= AOWL_OV_LOG_POLL_MS) {
            sinceLog = 0;
            aowl_ov_log_paths();
            aowl_ov_log_pull(AOWL_LOG_SERVER, buf, (int32_t)sizeof(buf));
            aowl_ov_log_pull(AOWL_LOG_CLIENT, buf, (int32_t)sizeof(buf));
        }

        Sleep(50);
        sinceFast += 50;
        sinceSlow += 50;
        sinceSync += 50;
        sinceLog += 50;
    }
    return 0;
}

/* Host thread. Must come after `aowl_ov_start`, which is what creates both the
 * critical section and the worker. */
static void aowl_ov_sync_start(const char* path, int32_t intervalMs) {
    if (!g_ov.started || !path || !path[0]) return;
    EnterCriticalSection(&g_ov.cs);
    aowl_ov_copy(g_ov.syncPath, (int32_t)sizeof(g_ov.syncPath), path);
    /* Floored rather than trusted. This is a poll against a local server on
     * behalf of a feature that changes a handful of times an hour; a caller
     * that asked for it every 50 ms would get a request per frame-ish for no
     * gain, and the failure would look like a slow game rather than a busy
     * loop. */
    g_ov.syncMs = intervalMs < 250 ? 250 : intervalMs;
    LeaveCriticalSection(&g_ov.cs);
}

static int32_t aowl_ov_sync_pending(void) {
    if (!g_ov.started) return 0;
    int32_t n = 0;
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.syncSerial != g_ov.syncTaken) n = g_ov.syncLen;
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

static int32_t aowl_ov_sync_attempts(void) {
    if (!g_ov.started) return 0;
    int32_t n;
    EnterCriticalSection(&g_ov.cs);
    n = g_ov.syncAttempts;
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* Copies the newest body out and marks it read. Returns its length, 0 when
 * there is nothing new, and -1 when `cap` is too small -- which is *not* the
 * same as nothing new: the caller sized its buffer from `aowl_ov_sync_pending`
 * and a short one means the body grew between the two calls, so the serial is
 * left alone and the next call gets it. */
static int32_t aowl_ov_sync_take(char* out, int32_t cap) {
    if (!g_ov.started || !out || cap <= 0) return 0;
    int32_t n = 0;
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.syncSerial == g_ov.syncTaken) {
        n = 0;
    } else if (g_ov.syncLen >= cap) {
        n = -1;
    } else {
        memcpy(out, g_ov.syncBody, (size_t)g_ov.syncLen);
        out[g_ov.syncLen] = 0;
        n = g_ov.syncLen;
        g_ov.syncTaken = g_ov.syncSerial;
    }
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* How many bodies the feed REFUSED, and what the last refusal was. A caller
 * that sees no body asks this before blaming the route: `*lastLen` is the
 * size of the last body that was thrown away and `*wasZlib` says it arrived
 * compressed (which means `Accept-Encoding: identity` was not honoured), so
 * "too large", "compressed" and "never answered" are three outcomes rather
 * than one. */
static int32_t aowl_ov_sync_drop_reason(int32_t* lastLen, int32_t* wasZlib) {
    int32_t n = 0;
    if (!g_ov.started) return 0;
    EnterCriticalSection(&g_ov.cs);
    n = g_ov.syncDrops;
    if (lastLen) *lastLen = g_ov.syncDropLen;
    if (wasZlib) *wasZlib = g_ov.syncDropZlib;
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* Arms one POST for the worker thread. Called from the host's own thread
 * (never the Unity main thread's), same requirement `aowl_ov_sync_start`
 * carries. Overwrites whatever was armed and not yet sent -- the caller owns
 * sequencing the single slot, same as it already does for the GET path. */
static void aowl_ov_post_start(const char* path, const char* body) {
    if (!g_ov.started || !path || !path[0]) return;
    EnterCriticalSection(&g_ov.cs);
    aowl_ov_copy(g_ov.postPath, (int32_t)sizeof(g_ov.postPath), path);
    aowl_ov_copy(g_ov.postBody, (int32_t)sizeof(g_ov.postBody), body ? body : "");
    g_ov.postArm = 1;
    LeaveCriticalSection(&g_ov.cs);
}

/* 1 while a request is armed or has been sent and not yet answered; 0 once the
 * response has landed (whether or not it has been taken yet -- `post_take`
 * still has it). The caller polls this to know when it may arm the next one. */
/* Read-and-clear. The host tick calls this once per tick; a kick that arrives
 * while a push is already in flight still lands, because the taker only clears
 * the bit and the bridge turns it into "collect on the next idle", not into an
 * action that has to happen right here. */
static int32_t aowl_ov_take_edit_kick(void) {
    return (int32_t)InterlockedExchange(&g_ov.editKick, 0);
}

static int32_t aowl_ov_post_pending(void) {
    if (!g_ov.started) return 0;
    int32_t n;
    EnterCriticalSection(&g_ov.cs);
    n = (g_ov.postArm || g_ov.postInFlight) ? 1 : 0;
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* The three-way stage behind `aowl_ov_post_pending`'s single bit. See the
 * forward declaration for why the distinction is load-bearing. */
static int32_t aowl_ov_post_stage(void) {
    int32_t n;
    if (!g_ov.started) return 0;
    EnterCriticalSection(&g_ov.cs);
    n = g_ov.postInFlight ? 2 : (g_ov.postArm ? 1 : 0);
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* THE WRITE LEG, AND WHY IT IS A FUNCTION.
 *
 * This used to be an inline block at the tail of the worker loop, which meant
 * it ran exactly once per pass -- and `aowl_ov_settings_verify` blocks that
 * same worker thread for up to AOWL_OV_VERIFY_TRIES * AOWL_OV_VERIFY_WAIT
 * (32 s). MEASURED against a live client on 2026-08-28: from the moment an
 * edit was POSTed, `GET /aowlspt/mods/panel` and `GET /aowlspt/mods/list`
 * stopped entirely and `POST /aowlspt/settings/client/sync` dropped from six
 * per five seconds to ONE per 31.3 s -- one per verify cap. The settings
 * bridge's 12 s stall budget expired first every time, so it reported "a
 * client settings push to the backend never came back" and dropped the push,
 * and the F12 edit riding on that push's reply was never applied.
 *
 * Worse, it could not resolve itself: the verify loop waits for this guid to
 * republish twice, and a republish IS a `client/sync` POST -- which only this
 * leg can send. Waiting on the worker for progress the worker is the sole
 * producer of is a deadlock with a 32-second timer on it.
 *
 * So the wait pumps this instead of sleeping through it. Cheap when nothing
 * is armed: one critical section and a return. WORKER THREAD ONLY. */
static void aowl_ov_pump_post(void) {
    wchar_t wpath[192];
    static char reqBody[AOWL_OV_POST_BODY];
    static char respBuf[AOWL_OV_SYNC_MAX];
    int32_t wantPost = 0;
    int32_t rc, ok, n;
    if (!g_ov.started) return;
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.postArm) {
        int32_t i = 0;
        for (; g_ov.postPath[i] && i < 191; i++)
            wpath[i] = (wchar_t)(unsigned char)g_ov.postPath[i];
        wpath[i] = 0;
        aowl_ov_copy(reqBody, (int32_t)sizeof(reqBody), g_ov.postBody);
        g_ov.postArm = 0;
        g_ov.postInFlight = 1;
        wantPost = 1;
    }
    LeaveCriticalSection(&g_ov.cs);
    if (!wantPost) return;

    /* Its own response buffer, not the worker loop's `buf`: this now runs from
     * inside `aowl_ov_settings_verify`, which is holding page bytes in the
     * buffer it passed down and re-reads them after the wait. */
    rc = aowl_ov_http(L"POST", wpath, reqBody, respBuf,
                      (int32_t)sizeof(respBuf));
    ok = (rc > 0 && (unsigned char)respBuf[0] != 0x78);
    EnterCriticalSection(&g_ov.cs);
    if (ok) {
        n = rc;
        if (n >= AOWL_OV_SYNC_MAX) n = AOWL_OV_SYNC_MAX - 1;
        memcpy(g_ov.postResp, respBuf, (size_t)n);
        g_ov.postResp[n] = 0;
        g_ov.postRespLen = n;
    } else {
        g_ov.postResp[0] = 0;
        g_ov.postRespLen = 0;
    }
    g_ov.postOk = ok;
    g_ov.postInFlight = 0;
    g_ov.postSerial++;
    LeaveCriticalSection(&g_ov.cs);
}

/* Copies the last completed POST's response out and marks it read, once.
 * Returns the body length (0 possible on a success with an empty body),
 * writes 1/0 to `*ok`, and returns -1 (leaving the serial untaken) only when
 * `cap` is too small for a body that is there -- mirrors `aowl_ov_sync_take`.
 * Returns 0 with `*ok` unset when nothing new has landed; the caller must
 * check `aowl_ov_post_pending` first to tell "still in flight" from "nothing
 * was ever armed". */
static int32_t aowl_ov_post_take(char* out, int32_t cap, int32_t* ok) {
    if (!g_ov.started || !out || cap <= 0 || !ok) return 0;
    int32_t n = 0;
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.postSerial == g_ov.postTaken) {
        n = 0;
    } else if (g_ov.postRespLen >= cap) {
        n = -1;
    } else {
        memcpy(out, g_ov.postResp, (size_t)g_ov.postRespLen);
        out[g_ov.postRespLen] = 0;
        n = g_ov.postRespLen;
        *ok = g_ov.postOk;
        g_ov.postTaken = g_ov.postSerial;
    }
    LeaveCriticalSection(&g_ov.cs);
    return n;
}

/* Called from the render thread. Copies, never blocks on anything but the
 * short data lock, and silently drops when the queue is full -- a full queue
 * means thirty-two unanswered gestures, at which point the backend is gone and
 * the thirty-third would not have worked either. */
static void aowl_ov_queue_cmd(int32_t kind, const char* arg, int32_t enabled) {
    /* With no backend port there is no worker thread, so a queued command would
     * sit there forever and the row it came from would show `~` for the rest of
     * the session -- a panel promising something it has no way to do. Refused
     * with the reason instead. This is the read-only configuration and it is a
     * legitimate one: the panel still lists what the client host loaded, which
     * is the one thing that cannot be stale. */
    if (g_ov.backendPort <= 0) {
        EnterCriticalSection(&g_ov.cs);
        aowl_ov_copy(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat),
                     "not sent: no backend is configured");
        aowl_ov_copy(g_ov.lastError, (int32_t)sizeof(g_ov.lastError),
                     "this overlay was started with no backend port, so it is "
                     "read-only: it can show what the client host loaded, and "
                     "it has nothing to ask about changing it.");
        g_ov.resultCount = 0;
        LeaveCriticalSection(&g_ov.cs);
        g_ov.dataSerial++;
        return;
    }
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.cmdCount < AOWL_OV_MAX_CMDS) {
        AowlOvCmd* c = &g_ov.cmds[g_ov.cmdCount++];
        c->kind = kind;
        aowl_ov_copy(c->guid, (int32_t)sizeof(c->guid), arg ? arg : "");
        c->enabled = enabled;
    }
    LeaveCriticalSection(&g_ov.cs);
}

static void aowl_ov_queue(const char* guid, int32_t enabled) {
    aowl_ov_queue_cmd(AOWL_CMD_TOGGLE, guid, enabled);
}

/* --- the per-mod enable leg. See the forward declarations for why this is a
 * queued command and not a new HTTP verb. Host thread; the table is the
 * worker's, so every read of it is under the same lock the worker writes it
 * under. */
static int32_t aowl_ov_mod_enabled(const char* guid) {
    int32_t r = -1;
    int32_t i;
    if (!g_ov.started || !guid || !guid[0]) return -1;
    EnterCriticalSection(&g_ov.cs);
    for (i = 0; i < g_ov.modCount; i++) {
        if (strcmp(g_ov.mods[i].guid, guid) == 0) {
            r = g_ov.mods[i].backendRow ? (g_ov.mods[i].enabled ? 1 : 0) : -2;
            break;
        }
    }
    LeaveCriticalSection(&g_ov.cs);
    return r;
}

/* 1 while a toggle for this guid has been queued and the manager has not yet
 * confirmed it. A verdict that reads the enable back MUST wait this out, or it
 * reads the value it just wrote optimistically into the table and can only
 * ever say yes. */
static int32_t aowl_ov_mod_pending(const char* guid) {
    int32_t r = 0;
    int32_t i;
    if (!g_ov.started || !guid || !guid[0]) return 0;
    EnterCriticalSection(&g_ov.cs);
    for (i = 0; i < g_ov.modCount; i++) {
        if (strcmp(g_ov.mods[i].guid, guid) == 0) {
            r = g_ov.mods[i].pending ? 1 : 0;
            break;
        }
    }
    LeaveCriticalSection(&g_ov.cs);
    return r;
}

static int32_t aowl_ov_mod_toggle(const char* guid, int32_t enabled) {
    int32_t found = 0, prot = 0;
    int32_t i;
    int32_t want = enabled ? 1 : 0;
    if (!g_ov.started || !guid || !guid[0]) return 0;
    if (g_ov.backendPort <= 0) return -2;
    EnterCriticalSection(&g_ov.cs);
    for (i = 0; i < g_ov.modCount; i++) {
        if (strcmp(g_ov.mods[i].guid, guid) == 0) {
            found = 1;
            if (g_ov.mods[i].protectedRow && !want) {
                prot = 1;
            } else {
                g_ov.mods[i].enabled = want;
                g_ov.mods[i].pending = 1;
            }
            break;
        }
    }
    LeaveCriticalSection(&g_ov.cs);
    if (!found) return 0;
    if (prot) return -1;
    g_ov.dataSerial++;
    aowl_ov_queue_cmd(AOWL_CMD_TOGGLE, guid, want);
    return 1;
}

/* The two settings-mode requests. They fully populate the slot (the shared
 * queue slot may hold a previous edit's key/value) and are silent when there is
 * no backend -- the settings screen says so itself rather than through the
 * mod-manager's error line. */
static void aowl_ov_queue_spage(const char* pageId, int32_t isMod) {
    if (g_ov.backendPort <= 0) return;
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.cmdCount < AOWL_OV_MAX_CMDS) {
        AowlOvCmd* c = &g_ov.cmds[g_ov.cmdCount++];
        memset(c, 0, sizeof(*c));
        c->kind = AOWL_CMD_SPAGE;
        aowl_ov_copy(c->guid, (int32_t)sizeof(c->guid), pageId ? pageId : "");
        c->enabled = isMod;
    }
    LeaveCriticalSection(&g_ov.cs);
}

static void aowl_ov_queue_sset(const char* pageId, const char* key,
                               const char* val) {
    int32_t i;
    if (g_ov.backendPort <= 0) return;
    EnterCriticalSection(&g_ov.cs);
    /* COALESCE, do not append. A slider drag emits an edit per notch; without
     * this, twelve notches fill a third of the command queue with values that
     * are all superseded before the worker reaches them, and the 33rd edit of
     * the session is dropped with nothing said. Replacing the value of an
     * SSET that is still queued for the same page+key sends exactly what the
     * player ended on, once. */
    for (i = 0; i < g_ov.cmdCount; i++) {
        AowlOvCmd* c = &g_ov.cmds[i];
        if (c->kind != AOWL_CMD_SSET) continue;
        if (strcmp(c->guid, pageId ? pageId : "") != 0) continue;
        if (strcmp(c->skey, key ? key : "") != 0) continue;
        aowl_ov_copy(c->sval, (int32_t)sizeof(c->sval), val ? val : "");
        /* Badge it NOW, on the UI thread, rather than when the worker gets to
         * it: an edit queued behind a verify that can run for tens of seconds
         * used to sit on screen looking untouched and fully editable. */
        (void)aowl_ov_pend_begin(pageId, key, val);
        aowl_ov_pend_apply();
        LeaveCriticalSection(&g_ov.cs);
        g_ov.dataSerial++;
        return;
    }
    if (g_ov.cmdCount < AOWL_OV_MAX_CMDS) {
        AowlOvCmd* c = &g_ov.cmds[g_ov.cmdCount++];
        memset(c, 0, sizeof(*c));
        c->kind = AOWL_CMD_SSET;
        aowl_ov_copy(c->guid, (int32_t)sizeof(c->guid), pageId ? pageId : "");
        aowl_ov_copy(c->skey, (int32_t)sizeof(c->skey), key ? key : "");
        aowl_ov_copy(c->sval, (int32_t)sizeof(c->sval), val ? val : "");
        (void)aowl_ov_pend_begin(pageId, key, val);
        aowl_ov_pend_apply();
    } else {
        /* NEVER A SILENT DROP. */
        aowl_ov_fmt(g_ov.writeWhy, (int32_t)sizeof(g_ov.writeWhy),
                    "NOT SENT: the overlay's command queue is full (%d). This "
                    "edit to %s was NOT queued and NOT applied -- nothing was "
                    "changed. Wait for the queue to drain and set it again.",
                    (int32_t)AOWL_OV_MAX_CMDS, key ? key : "(no key)");
    }
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
}

/* ================================================================== *
 * Immediate-mode drawing
 *
 * One vertex buffer, one draw call, no index buffer. Six vertices per quad
 * rather than four plus indices: at a thousand quads the extra 40 KB of upload
 * is free and it removes an IA state (and its backup/restore) from the frame.
 * ================================================================== */

static void aowl_ov_vert(float x, float y, float u, float v, uint32_t col) {
    /* Dropped rather than grown -- the render thread does not allocate. It is
     * counted because a silently truncated frame reads as missing text rather
     * than as a full buffer, and `AOWL_OV_MAX_VERTS` is a number somebody has
     * to be able to check rather than trust. */
    if (g_ov.vtxCount >= AOWL_OV_MAX_VERTS) { g_ov.vtxDropped++; return; }
    AowlOvVert* p = &g_ov.vtx[g_ov.vtxCount++];
    /* The one place the scale is applied. Everything above this line -- every
     * layout constant, every column offset, every hit test -- is in panel units
     * at 1x, which is what keeps a 3,840-pixel-wide back buffer from being a
     * second set of magic numbers. */
    {
        float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
        p->x = x * k; p->y = y * k;
    }
    p->u = u; p->v = v; p->col = col;
}

static void aowl_ov_quad_uv(float x, float y, float w, float h,
                            float u0, float v0, float u1, float v1, uint32_t col) {
    if (g_ov.vtxCount + 6 > AOWL_OV_MAX_VERTS) { g_ov.vtxDropped += 6; return; }
    aowl_ov_vert(x,     y,     u0, v0, col);
    aowl_ov_vert(x + w, y,     u1, v0, col);
    aowl_ov_vert(x,     y + h, u0, v1, col);
    aowl_ov_vert(x + w, y,     u1, v0, col);
    aowl_ov_vert(x + w, y + h, u1, v1, col);
    aowl_ov_vert(x,     y + h, u0, v1, col);
}

static void aowl_ov_rect(float x, float y, float w, float h, uint32_t col) {
    aowl_ov_quad_uv(x, y, w, h, AOWL_OV_WHITE_U, AOWL_OV_WHITE_V,
                    AOWL_OV_WHITE_U, AOWL_OV_WHITE_V, col);
}

static void aowl_ov_frame_rect(float x, float y, float w, float h, float t,
                               uint32_t col) {
    aowl_ov_rect(x, y, w, t, col);
    aowl_ov_rect(x, y + h - t, w, t, col);
    aowl_ov_rect(x, y + t, t, h - 2 * t, col);
    aowl_ov_rect(x + w - t, y + t, t, h - 2 * t, col);
}

/* Text at exactly one texel per pixel. The sampler is POINT/CLAMP and the
 * quads land on integer pixel positions, so glyphs are crisp rather than the
 * soft mush a bilinear sample of an 8x16 cell produces. */
static float aowl_ov_text(float x, float y, const char* s, uint32_t col) {
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c < 32 || c > 126) c = '?';
        int32_t idx = c - 32;
        float u0 = (float)((idx % 16) * AOWL_OV_CW) / (float)AOWL_OV_ATW;
        float v0 = (float)((idx / 16) * AOWL_OV_CH) / (float)AOWL_OV_ATH;
        float u1 = u0 + (float)AOWL_OV_CW / (float)AOWL_OV_ATW;
        float v1 = v0 + (float)AOWL_OV_CH / (float)AOWL_OV_ATH;
        aowl_ov_quad_uv(x, y, (float)AOWL_OV_CW, (float)AOWL_OV_CH,
                        u0, v0, u1, v1, col);
        x += (float)AOWL_OV_CW;
    }
    return x;
}

/* ================================================================== *
 * Device objects
 * ================================================================== */

static const GUID AOWL_IID_ID3D11Device =
    { 0xdb6f6ddb, 0xac77, 0x4e88, { 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 } };
static const GUID AOWL_IID_ID3D11Texture2D =
    { 0x6f15aaf2, 0xd208, 0x4e89, { 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

static void aowl_ov_release_targets(void) {
    if (g_ov.rtv) { ID3D11RenderTargetView_Release(g_ov.rtv); g_ov.rtv = NULL; }
}

static void aowl_ov_release_all(void) {
    /* Everything device-bound goes, the vertex buffer with it, so whatever the
     * cache thinks is on the GPU is not there any more. */
    g_ov.drawSig = 0;
    g_ov.needUpload = 1;
    g_ov.sigBbW = 0;
    g_ov.sigBbH = 0;
    aowl_ov_release_targets();
    if (g_ov.samp)   { ID3D11SamplerState_Release(g_ov.samp); g_ov.samp = NULL; }
    if (g_ov.font)   { ID3D11ShaderResourceView_Release(g_ov.font); g_ov.font = NULL; }
    if (g_ov.depth)  { ID3D11DepthStencilState_Release(g_ov.depth); g_ov.depth = NULL; }
    if (g_ov.rast)   { ID3D11RasterizerState_Release(g_ov.rast); g_ov.rast = NULL; }
    if (g_ov.blend)  { ID3D11BlendState_Release(g_ov.blend); g_ov.blend = NULL; }
    if (g_ov.cb)     { ID3D11Buffer_Release(g_ov.cb); g_ov.cb = NULL; }
    if (g_ov.vb)     { ID3D11Buffer_Release(g_ov.vb); g_ov.vb = NULL; }
    if (g_ov.layout) { ID3D11InputLayout_Release(g_ov.layout); g_ov.layout = NULL; }
    if (g_ov.ps)     { ID3D11PixelShader_Release(g_ov.ps); g_ov.ps = NULL; }
    if (g_ov.psTex)  { ID3D11PixelShader_Release(g_ov.psTex); g_ov.psTex = NULL; }
    /* EVERY cached tile SRV goes with the device, and the whole cache is
     * cleared -- not just released. A surviving `key` with a dangling `srv`
     * after a resolution change would be looked up, found, and drawn from
     * freed memory. The next frame re-uploads from the host's CPU table,
     * which is still there, so nothing is lost but time. */
    {
        int32_t ti;
        for (ti = 0; ti < AOWL_OV_TEX_MAX; ti++) {
            if (g_ov.texc[ti].srv)
                ID3D11ShaderResourceView_Release(g_ov.texc[ti].srv);
        }
        memset(g_ov.texc, 0, sizeof(g_ov.texc));
    }
    g_ov.spanN = 0;
    if (g_ov.vs)     { ID3D11VertexShader_Release(g_ov.vs); g_ov.vs = NULL; }
    if (g_ov.ctx)    { ID3D11DeviceContext_Release(g_ov.ctx); g_ov.ctx = NULL; }
    if (g_ov.dev)    { ID3D11Device_Release(g_ov.dev); g_ov.dev = NULL; }
    g_ov.swap = NULL;
}

static int32_t aowl_ov_make_font(void) {
    /* The 1-bit table is expanded to R8_UNORM once. R8 rather than RGBA8
     * because the shader only wants coverage, and 14 KB rather than 56 KB is
     * 14 KB the game's texture pool does not lose. */
    static uint8_t px[AOWL_OV_ATH][AOWL_OV_ATW];
    memset(px, 0, sizeof(px));
    for (int32_t g = 0; g < 95; g++) {
        int32_t cx = (g % 16) * AOWL_OV_CW;
        int32_t cy = (g / 16) * AOWL_OV_CH;
        for (int32_t r = 0; r < AOWL_OV_CH; r++) {
            uint8_t bits = aowl_ov_font[g][r];
            for (int32_t b = 0; b < AOWL_OV_CW; b++)
                px[cy + r][cx + b] = (bits & (0x80u >> b)) ? 0xFF : 0x00;
        }
    }
    px[96][0] = 0xFF;   /* the opaque texel every solid quad samples */

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = AOWL_OV_ATW;
    td.Height = AOWL_OV_ATH;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA sd;
    memset(&sd, 0, sizeof(sd));
    sd.pSysMem = px;
    sd.SysMemPitch = AOWL_OV_ATW;

    ID3D11Texture2D* tex = NULL;
    if (FAILED(ID3D11Device_CreateTexture2D(g_ov.dev, &td, &sd, &tex))) return 0;
    HRESULT hr = ID3D11Device_CreateShaderResourceView(g_ov.dev,
                    (ID3D11Resource*)tex, NULL, &g_ov.font);
    ID3D11Texture2D_Release(tex);
    return SUCCEEDED(hr);
}

static int32_t aowl_ov_make_device_objects(void) {
    if (FAILED(ID3D11Device_CreateVertexShader(g_ov.dev, aowl_ov_vs,
                                               sizeof(aowl_ov_vs), NULL, &g_ov.vs)))
        return 0;
    /* The textured-quad shader is NOT fatal if it fails: without it the
     * overlay loses map artwork and keeps everything else, which is a much
     * better outcome than no overlay. `aowl_ov_region_append` checks
     * `g_ov.psTex` before it emits a single textured vertex, so a NULL here
     * means textured quads are counted as misses, not drawn with the wrong
     * shader. */
    if (FAILED(ID3D11Device_CreatePixelShader(g_ov.dev, aowl_ov_ps_tex,
                                              sizeof(aowl_ov_ps_tex), NULL,
                                              &g_ov.psTex)))
        g_ov.psTex = NULL;
    if (FAILED(ID3D11Device_CreatePixelShader(g_ov.dev, aowl_ov_ps,
                                              sizeof(aowl_ov_ps), NULL, &g_ov.ps)))
        return 0;

    D3D11_INPUT_ELEMENT_DESC el[3];
    memset(el, 0, sizeof(el));
    el[0].SemanticName = "POSITION";
    el[0].Format = DXGI_FORMAT_R32G32_FLOAT;
    el[0].AlignedByteOffset = 0;
    el[1].SemanticName = "TEXCOORD";
    el[1].Format = DXGI_FORMAT_R32G32_FLOAT;
    el[1].AlignedByteOffset = 8;
    el[2].SemanticName = "COLOR";
    el[2].Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    el[2].AlignedByteOffset = 16;
    if (FAILED(ID3D11Device_CreateInputLayout(g_ov.dev, el, 3, aowl_ov_vs,
                                              sizeof(aowl_ov_vs), &g_ov.layout)))
        return 0;

    D3D11_BUFFER_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = sizeof(AowlOvVert) * AOWL_OV_MAX_VERTS;
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(ID3D11Device_CreateBuffer(g_ov.dev, &bd, NULL, &g_ov.vb))) return 0;

    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = 16;                  /* one float4; must be 16-byte aligned */
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(ID3D11Device_CreateBuffer(g_ov.dev, &bd, NULL, &g_ov.cb))) return 0;

    D3D11_BLEND_DESC bl;
    memset(&bl, 0, sizeof(bl));
    bl.RenderTarget[0].BlendEnable = TRUE;
    bl.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    bl.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bl.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    /* The back buffer's alpha channel is the desktop compositor's business on
     * a flip-model swap chain. Writing INV_SRC_ALPHA into it would make the
     * game's window translucent where the panel is. Leave alpha at ONE/ZERO
     * over the destination... which is SrcAlpha=ONE, DestAlpha=INV_SRC_ALPHA:
     * standard "over" in alpha too, so a composited window stays opaque where
     * the game was opaque. */
    bl.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bl.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    bl.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bl.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(ID3D11Device_CreateBlendState(g_ov.dev, &bl, &g_ov.blend))) return 0;

    D3D11_RASTERIZER_DESC rd;
    memset(&rd, 0, sizeof(rd));
    rd.FillMode = D3D11_FILL_SOLID;
    /* Cull NONE, because the winding of our quads is whatever the pixel-space
     * y-flip makes it and there is no reason to care. Scissor OFF explicitly:
     * the game may have left a scissor rect that would clip the panel to
     * nothing, and a rasteriser state with ScissorEnable=FALSE ignores it. */
    rd.CullMode = D3D11_CULL_NONE;
    rd.ScissorEnable = FALSE;
    rd.DepthClipEnable = TRUE;
    if (FAILED(ID3D11Device_CreateRasterizerState(g_ov.dev, &rd, &g_ov.rast))) return 0;

    D3D11_DEPTH_STENCIL_DESC dd;
    memset(&dd, 0, sizeof(dd));
    /* Depth test and write off, stencil off. The overlay is the last thing
     * drawn and must not be occluded by whatever the game left in the depth
     * buffer -- which, at Present, is a full frame of geometry. */
    dd.DepthEnable = FALSE;
    dd.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
    dd.StencilEnable = FALSE;
    if (FAILED(ID3D11Device_CreateDepthStencilState(g_ov.dev, &dd, &g_ov.depth)))
        return 0;

    D3D11_SAMPLER_DESC sm;
    memset(&sm, 0, sizeof(sm));
    sm.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sm.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sm.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sm.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sm.ComparisonFunc = D3D11_COMPARISON_ALWAYS;
    if (FAILED(ID3D11Device_CreateSamplerState(g_ov.dev, &sm, &g_ov.samp))) return 0;

    return aowl_ov_make_font();
}

static int32_t aowl_ov_make_rtv(IDXGISwapChain* sc) {
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(sc, 0, &AOWL_IID_ID3D11Texture2D, (void**)&bb)))
        return 0;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(bb, &td);
    g_ov.bbW = td.Width;
    g_ov.bbH = td.Height;
    /* NULL desc: the view takes the buffer's own format. Naming a format here
     * is how an overlay ends up washed out on an sRGB back buffer or refused
     * outright on a typeless one. */
    HRESULT hr = ID3D11Device_CreateRenderTargetView(g_ov.dev, (ID3D11Resource*)bb,
                                                     NULL, &g_ov.rtv);
    ID3D11Texture2D_Release(bb);
    return SUCCEEDED(hr);
}

/* ================================================================== *
 * State backup
 * ================================================================== */

typedef struct AowlOvSaved {
    UINT                      viewportCount, scissorCount;
    D3D11_VIEWPORT            viewports[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE];
    D3D11_RECT                scissors[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE];
    ID3D11RasterizerState*    rast;
    ID3D11BlendState*         blend;
    FLOAT                     blendFactor[4];
    UINT                      sampleMask;
    ID3D11DepthStencilState*  depth;
    UINT                      stencilRef;
    ID3D11RenderTargetView*   rtvs[D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT];
    ID3D11DepthStencilView*   dsv;
    ID3D11ShaderResourceView* srv;
    ID3D11SamplerState*       samp;
    ID3D11PixelShader*        ps;
    ID3D11VertexShader*       vs;
    ID3D11GeometryShader*     gs;
    ID3D11HullShader*         hs;
    ID3D11DomainShader*       ds;
    ID3D11ClassInstance*      psInst[256];
    ID3D11ClassInstance*      vsInst[256];
    ID3D11ClassInstance*      gsInst[256];
    UINT                      psInstN, vsInstN, gsInstN;
    ID3D11Buffer*             vsCb;
    D3D11_PRIMITIVE_TOPOLOGY  topology;
    ID3D11Buffer*             ib;
    DXGI_FORMAT               ibFormat;
    UINT                      ibOffset;
    ID3D11Buffer*             vb;
    UINT                      vbStride, vbOffset;
    ID3D11InputLayout*        layout;
} AowlOvSaved;

static void aowl_ov_save(ID3D11DeviceContext* c, AowlOvSaved* s) {
    memset(s, 0, sizeof(*s));
    s->viewportCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    ID3D11DeviceContext_RSGetViewports(c, &s->viewportCount, s->viewports);
    s->scissorCount = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    ID3D11DeviceContext_RSGetScissorRects(c, &s->scissorCount, s->scissors);
    ID3D11DeviceContext_RSGetState(c, &s->rast);
    ID3D11DeviceContext_OMGetBlendState(c, &s->blend, s->blendFactor, &s->sampleMask);
    ID3D11DeviceContext_OMGetDepthStencilState(c, &s->depth, &s->stencilRef);
    ID3D11DeviceContext_OMGetRenderTargets(c, D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT,
                                           s->rtvs, &s->dsv);
    ID3D11DeviceContext_PSGetShaderResources(c, 0, 1, &s->srv);
    ID3D11DeviceContext_PSGetSamplers(c, 0, 1, &s->samp);
    s->psInstN = 256; s->vsInstN = 256; s->gsInstN = 256;
    ID3D11DeviceContext_PSGetShader(c, &s->ps, s->psInst, &s->psInstN);
    ID3D11DeviceContext_VSGetShader(c, &s->vs, s->vsInst, &s->vsInstN);
    ID3D11DeviceContext_GSGetShader(c, &s->gs, s->gsInst, &s->gsInstN);
    ID3D11DeviceContext_HSGetShader(c, &s->hs, NULL, NULL);
    ID3D11DeviceContext_DSGetShader(c, &s->ds, NULL, NULL);
    ID3D11DeviceContext_VSGetConstantBuffers(c, 0, 1, &s->vsCb);
    ID3D11DeviceContext_IAGetPrimitiveTopology(c, &s->topology);
    ID3D11DeviceContext_IAGetIndexBuffer(c, &s->ib, &s->ibFormat, &s->ibOffset);
    ID3D11DeviceContext_IAGetVertexBuffers(c, 0, 1, &s->vb, &s->vbStride, &s->vbOffset);
    ID3D11DeviceContext_IAGetInputLayout(c, &s->layout);
}

/* Every Get above returned a reference. Restore, then drop them all — this
 * function is the other half of `aowl_ov_save` and skipping any single Release
 * leaks that object once per frame, forever. */
static void aowl_ov_restore(ID3D11DeviceContext* c, AowlOvSaved* s) {
    ID3D11DeviceContext_RSSetViewports(c, s->viewportCount, s->viewports);
    ID3D11DeviceContext_RSSetScissorRects(c, s->scissorCount, s->scissors);
    ID3D11DeviceContext_RSSetState(c, s->rast);
    if (s->rast) ID3D11RasterizerState_Release(s->rast);
    ID3D11DeviceContext_OMSetBlendState(c, s->blend, s->blendFactor, s->sampleMask);
    if (s->blend) ID3D11BlendState_Release(s->blend);
    ID3D11DeviceContext_OMSetDepthStencilState(c, s->depth, s->stencilRef);
    if (s->depth) ID3D11DepthStencilState_Release(s->depth);
    ID3D11DeviceContext_OMSetRenderTargets(c, D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT,
                                           s->rtvs, s->dsv);
    for (UINT i = 0; i < D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT; i++)
        if (s->rtvs[i]) ID3D11RenderTargetView_Release(s->rtvs[i]);
    if (s->dsv) ID3D11DepthStencilView_Release(s->dsv);
    ID3D11DeviceContext_PSSetShaderResources(c, 0, 1, &s->srv);
    if (s->srv) ID3D11ShaderResourceView_Release(s->srv);
    ID3D11DeviceContext_PSSetSamplers(c, 0, 1, &s->samp);
    if (s->samp) ID3D11SamplerState_Release(s->samp);
    ID3D11DeviceContext_PSSetShader(c, s->ps, s->psInst, s->psInstN);
    if (s->ps) ID3D11PixelShader_Release(s->ps);
    for (UINT i = 0; i < s->psInstN; i++)
        if (s->psInst[i]) ID3D11ClassInstance_Release(s->psInst[i]);
    ID3D11DeviceContext_VSSetShader(c, s->vs, s->vsInst, s->vsInstN);
    if (s->vs) ID3D11VertexShader_Release(s->vs);
    for (UINT i = 0; i < s->vsInstN; i++)
        if (s->vsInst[i]) ID3D11ClassInstance_Release(s->vsInst[i]);
    ID3D11DeviceContext_GSSetShader(c, s->gs, s->gsInst, s->gsInstN);
    if (s->gs) ID3D11GeometryShader_Release(s->gs);
    for (UINT i = 0; i < s->gsInstN; i++)
        if (s->gsInst[i]) ID3D11ClassInstance_Release(s->gsInst[i]);
    ID3D11DeviceContext_HSSetShader(c, s->hs, NULL, 0);
    if (s->hs) ID3D11HullShader_Release(s->hs);
    ID3D11DeviceContext_DSSetShader(c, s->ds, NULL, 0);
    if (s->ds) ID3D11DomainShader_Release(s->ds);
    ID3D11DeviceContext_VSSetConstantBuffers(c, 0, 1, &s->vsCb);
    if (s->vsCb) ID3D11Buffer_Release(s->vsCb);
    ID3D11DeviceContext_IASetPrimitiveTopology(c, s->topology);
    ID3D11DeviceContext_IASetIndexBuffer(c, s->ib, s->ibFormat, s->ibOffset);
    if (s->ib) ID3D11Buffer_Release(s->ib);
    ID3D11DeviceContext_IASetVertexBuffers(c, 0, 1, &s->vb, &s->vbStride, &s->vbOffset);
    if (s->vb) ID3D11Buffer_Release(s->vb);
    ID3D11DeviceContext_IASetInputLayout(c, s->layout);
    if (s->layout) ID3D11InputLayout_Release(s->layout);
}

/* ================================================================== *
 * The panel
 *
 * Four views over one registry, driven from the keyboard, because the mouse in
 * a raid belongs to the game: Tarkov captures the cursor and reads it through
 * raw input, and while an overlay can integrate raw deltas into a cursor of its
 * own (it does -- see the WM_INPUT case), asking a player to *aim* at a 56-pixel
 * button with a mouse that is also turning their character is a worse gesture
 * than pressing a key. So every action has a key, the keys are printed on
 * screen, and the mouse is the convenience rather than the interface.
 *
 *   MODS      every mod, its verdict, and the manager's own sentence saying why
 *   LISTS     the named lists, which are active, and what each one contains
 *   ISSUES    conflicts and unmet requirements -- before you apply, not after
 *   APPLY     the outcome of the last change, per mod, in the host's words
 *
 * Nothing on any of them is composed here. `verdict`, `reason`, `from`,
 * `explicit`, `control`, `inEffect`, `outcome` and `message` are all printed as
 * the manager wrote them. The overlay's job is to put them where they can be
 * read, not to have an opinion about them -- an opinion formed in C, one poll
 * behind, would be a second resolver disagreeing with the real one.
 * ================================================================== */

#define AOWL_OV_PANEL_X   40
#define AOWL_OV_PANEL_Y   60
#define AOWL_OV_PANEL_W  940
#define AOWL_OV_PANEL_H  620
#define AOWL_OV_TITLE_H   26
#define AOWL_OV_TABS_H    22
#define AOWL_OV_STAT_H    20
#define AOWL_OV_HEAD_H    (AOWL_OV_TITLE_H + AOWL_OV_TABS_H + AOWL_OV_STAT_H)
#define AOWL_OV_ROW_H     22
#define AOWL_OV_LINE_H    16
#define AOWL_OV_PAD       10
#define AOWL_OV_BTN_W     56
/* 4 padding + guid + two wrapped lines of `reason` + the verdict line + two
 * wrapped lines about the client host. It grew by a line when the client host
 * started answering: that line is drawn for every row, including the ones it
 * has nothing to say about, because "unknown, and here is why" is the fact this
 * pane exists to carry. */
#define AOWL_OV_DETAIL_H  100   /* the selected row, explained */
/* Two lines -- the keys, and the markers -- which is what they take on a panel
 * wide enough to hold them. It is the floor, not the height: `aowl_ov_build`
 * measures both strings against the room and gives each up to
 * `AOWL_OV_LEGEND_MAX` lines. */
#define AOWL_OV_LEGEND_H  40
#define AOWL_OV_LEGEND_MAX 3
/* Drawn frames this opening has to contribute before the frame cost on the
 * title bar stops being labelled as the previous opening's. One EWMA time
 * constant at 1/32 -- about half a second at 60 Hz -- after which the old
 * session's number carries about a third of the weight and falling. */
#define AOWL_OV_COST_SETTLE  32


#define OV_DOT '.'
#define OV_SP  ' '

static int32_t aowl_ov_hit(float x, float y, float w, float h) {
    /* The cursor is in back-buffer pixels and the rectangle is in panel units,
     * so the cursor comes down rather than the rectangle going up -- one divide
     * instead of four multiplies, and no rounding to disagree about. */
    float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float mx = (float)g_ov.mx / k, my = (float)g_ov.my / k;
    return mx >= x && mx < x + w && my >= y && my < y + h;
}

/* ------------------------------------------------------------------ *
 * The panel own preferences -- where it sits, how big it is, how solid,
 * and whether the launch hint is wanted.
 *
 * A four-line text file under %LOCALAPPDATA%\aowlspt, written by the WORKER
 * thread and never by the render thread: the render thread is the game's
 * Present, and a synchronous file write in Present is a frame spike the
 * player feels. The render thread only ever sets `prefsDirty`.
 *
 * Deliberately NOT the host's `aowlspt-host.json`. That file is the host's
 * feature flags, edited by hand and by `tools/hostcfg.py`, and a window
 * position that rewrites itself every time somebody drags the panel would
 * fight both. This is view state, and it lives with the view.
 * ------------------------------------------------------------------ */

static void aowl_ov_prefs_path(void) {
    char base[240];
    DWORD n;
    if (g_ov.prefsPath[0]) return;
    n = GetEnvironmentVariableA("LOCALAPPDATA", base, (DWORD)sizeof(base));
    if (n == 0 || n >= sizeof(base)) { g_ov.prefsPath[0] = 0; return; }
    /* The separator must be an ESCAPED backslash -- two characters in the C
     * source. It was a single one for the whole life of this file, and in C a
     * lone backslash before `a` is BEL (0x07) -- a control character Windows
     * refuses
     * in a path -- so `CreateDirectoryA` failed with ERROR_INVALID_NAME every
     * launch, the `aowlspt` directory was never created, and `fopen(.., "wb")`
     * in `aowl_ov_prefs_save` then failed and returned silently. MEASURED: the
     * `aowlspt` folder under LOCALAPPDATA did not exist on a machine that has
     * run this overlay hundreds of times. Nothing here has ever persisted --
     * not the theme, not showFooter/savePos/animate/showUnimpl/navW/scalePref,
     * not the window geometry. The user reported it as "the theme is back to
     * normal every launch" and guessed "a general settings persistence bug";
     * they were right, and it was one character. */
    _snprintf(g_ov.prefsPath, sizeof(g_ov.prefsPath) - 1, "%s\\aowlspt", base);
    g_ov.prefsPath[sizeof(g_ov.prefsPath) - 1] = 0;
    CreateDirectoryA(g_ov.prefsPath, NULL);   /* fine if it is already there */
    _snprintf(g_ov.prefsPath, sizeof(g_ov.prefsPath) - 1,
              "%s\\aowlspt\\overlay-window.txt", base);
    g_ov.prefsPath[sizeof(g_ov.prefsPath) - 1] = 0;
}

/* Defaults, applied when there is no file or the file is unusable. Separate
 * from the load so that a corrupt file produces the SAME panel a first run
 * does rather than a panel with three fields set and one garbage. */
static void aowl_ov_prefs_default(void) {
    g_ov.panX = (float)AOWL_OV_PANEL_X;
    g_ov.panY = (float)AOWL_OV_PANEL_Y;
    g_ov.panW = (float)AOWL_OV_PANEL_W;
    g_ov.panH = (float)AOWL_OV_PANEL_H;
    g_ov.panMax = 0;
    g_ov.panAlpha = 232;          /* what this panel always was */
    g_ov.hintEnabled = 1;
    /* Every one of these is the behaviour the panel had before it was
     * settable, so a first run and an install that never opens this page look
     * identical to what shipped. */
    g_ov.showFooter = 1;
    g_ov.savePos = 1;
    g_ov.navW = 256;
    g_ov.animate = 1;
    aowl_ov_copy(g_ov.themeName, (int32_t)sizeof(g_ov.themeName), "Dark");
}

/* The `key=value` tail of the prefs file -- everything after the legacy first
 * line. Shared by the loader and, in reverse, by the writer. Range-checked one
 * key at a time rather than all-or-nothing: unlike the geometry, a bad
 * `navW` cannot strand the window, so one unusable key must not throw away the
 * fifteen good ones next to it. */
/* What the `theme=` line on disk ACTUALLY said, kept separate from
 * `g_ov.themeName` -- which by the time anything checks it may hold a default,
 * a fallback, or a live user pick. Comparing the live value against itself is
 * the check that cannot fail (CLAUDE.md 9b); this is the other operand. Empty
 * means the file named no theme, which is INCONCLUSIVE, not PASS. */
static char g_ovPrefsDiskTheme[32];

static void aowl_ov_prefs_kv(const char* k, const char* v) {
    int32_t n = atoi(v);
    if (!strcmp(k, "showFooter")) { if (n == 0 || n == 1) g_ov.showFooter = n; }
    else if (!strcmp(k, "savePos")) { if (n == 0 || n == 1) g_ov.savePos = n; }
    else if (!strcmp(k, "animate")) { if (n == 0 || n == 1) g_ov.animate = n; }
    else if (!strcmp(k, "showUnimpl")) { if (n == 0 || n == 1) g_ov.showUnimpl = n; }
    else if (!strcmp(k, "navW")) { if (n >= 140 && n <= 640) g_ov.navW = n; }
    else if (!strcmp(k, "scalePref")) { if (n >= 0 && n <= 3) g_ov.scalePref = n; }
    else if (!strcmp(k, "theme")) {
        aowl_ov_copy(g_ov.themeName, (int32_t)sizeof(g_ov.themeName), v);
        aowl_ov_copy(g_ovPrefsDiskTheme, (int32_t)sizeof(g_ovPrefsDiskTheme), v);
    }
}

static void aowl_ov_prefs_load(void) {
    FILE* f;
    int x = 0, y = 0, w = 0, hh = 0, mx = 0, al = 0, hi = 1;
    aowl_ov_prefs_default();
    g_ovPrefsDiskTheme[0] = 0;
    aowl_ov_prefs_path();
    if (!g_ov.prefsPath[0]) {
        aowl_ov_note("window prefs: no LOCALAPPDATA; using defaults, not persisting");
        return;
    }
    f = fopen(g_ov.prefsPath, "rb");
    if (!f) {
        /* Not an error: this is what a first launch looks like. Said out loud
         * anyway, because "the panel forgot where it was" and "the panel has
         * never been told where it was" are otherwise the same screen. */
        aowl_ov_note("window prefs: none on disk yet (first run)");
        return;
    }
    if (fscanf(f, "%d %d %d %d %d %d %d", &x, &y, &w, &hh, &mx, &al, &hi) == 7) {
        /* Every field is range-checked, and a single bad one throws the WHOLE
         * record away. A file that half-parses is how a panel ends up 3 pixels
         * wide off the bottom of the screen with no way to grab it. */
        if (x >= -4000 && x <= 8000 && y >= -4000 && y <= 8000 &&
            w >= 480 && w <= 8000 && hh >= 220 && hh <= 8000 &&
            (mx == 0 || mx == 1) && al >= 40 && al <= 255 &&
            (hi == 0 || hi == 1)) {
            g_ov.panX = (float)x; g_ov.panY = (float)y;
            g_ov.panW = (float)w; g_ov.panH = (float)hh;
            g_ov.panMax = mx; g_ov.panAlpha = al; g_ov.hintEnabled = hi;
        } else {
            aowl_ov_note("window prefs: out of range, defaults used");
        }
    } else {
        aowl_ov_note("window prefs: unreadable, defaults used");
    }
    /* The `key=value` tail. Read with `fgets` from wherever the first line
     * left the stream, so an OLD seven-integer file simply has no tail and an
     * old BUILD reading a new file stops after the first line: the format is
     * forward and backward compatible without a version number to get wrong. */
    {
        char line[160];
        while (fgets(line, (int32_t)sizeof(line), f)) {
            char* eq = strchr(line, '=');
            char* nl;
            if (!eq) continue;
            *eq = 0;
            nl = eq + 1;
            while (*nl && *nl != '\n' && *nl != '\r') nl++;
            *nl = 0;
            aowl_ov_prefs_kv(line, eq + 1);
        }
    }
    fclose(f);
    /* The value AS ACTUALLY READ, not the default the source declares -- a
     * default is not a value, and a flag whose deployed value differs from its
     * source default has cost this project launches. */
    aowl_ov_fmt(g_ov.status, (int32_t)sizeof(g_ov.status),
                "window prefs read: %dx%d at %d,%d max=%d alpha=%d launchHint=%d",
                (int32_t)g_ov.panW, (int32_t)g_ov.panH, (int32_t)g_ov.panX,
                (int32_t)g_ov.panY, g_ov.panMax, g_ov.panAlpha, g_ov.hintEnabled);
}

static void aowl_ov_prefs_save(void) {
    FILE* f;
    if (!g_ov.prefsPath[0]) return;
    f = fopen(g_ov.prefsPath, "wb");
    /* SAY SO. This returned silently for the whole life of the file, which is
     * how a broken path spent months looking like a working one: every
     * preference appeared to take, and every one was gone next launch. A
     * setting that cannot be persisted must announce that it cannot be
     * persisted -- the silent-reset shape is exactly what made this panel feel
     * broken. Announced once per path, not once per keystroke. */
    if (!f) {
        if (!g_ov.prefsSaveFailed) {
            g_ov.prefsSaveFailed = 1;
            aowl_ov_note("window prefs: CANNOT WRITE the preferences file, so "
                         "nothing set here will survive a restart");
        }
        return;
    }
    g_ov.prefsSaveFailed = 0;
    fprintf(f, "%d %d %d %d %d %d %d\n",
            (int)g_ov.panX, (int)g_ov.panY, (int)g_ov.panW, (int)g_ov.panH,
            g_ov.panMax, g_ov.panAlpha, g_ov.hintEnabled);
    /* The tail. One line per key, written unconditionally rather than only for
     * non-defaults: a file that lists every key is a file a person can EDIT,
     * and this file is now the same kind of artifact a theme file is. */
    fprintf(f, "showFooter=%d\nsavePos=%d\nanimate=%d\nshowUnimpl=%d\n"
               "navW=%d\nscalePref=%d\ntheme=%s\n",
            g_ov.showFooter, g_ov.savePos, g_ov.animate, g_ov.showUnimpl,
            g_ov.navW, g_ov.scalePref, g_ov.themeName);
    fclose(f);
}


/* ------------------------------------------------------------------ *
 * Text helpers
 * ------------------------------------------------------------------ */

/* Text clipped to `cols` characters, with an ellipsis when it did not fit. A
 * silently truncated mod id reads as a different mod id. */
static void aowl_ov_textn(float x, float y, const char* s, uint32_t col,
                          int32_t cols) {
    char buf[224];
    int32_t n = (int32_t)strlen(s);
    if (cols <= 0) return;
    if (cols > (int32_t)sizeof(buf) - 1) cols = (int32_t)sizeof(buf) - 1;
    if (n <= cols) {
        aowl_ov_text(x, y, s, col);
        return;
    }
    memcpy(buf, s, (size_t)cols);
    buf[cols] = 0;
    if (cols >= 3) { buf[cols - 1] = '.'; buf[cols - 2] = '.'; }
    aowl_ov_text(x, y, buf, col);
}

/* Word-wrapped text. Returns the number of lines drawn, and stops at
 * `maxLines` -- the manager's sentences are one line by design and its error
 * strings are three, so this exists for the long ones rather than for all of
 * them. Newlines in the source break the line too.
 *
 * `draw` is 0 for a caller that only wants the count. The legend has to know
 * how tall it is before the body is laid out, and then draw the same text into
 * the room it reserved; the two answers cannot be allowed to disagree, so they
 * are one function rather than one rule written twice. */
static int32_t aowl_ov_wrap_ex(float x, float y, const char* s, uint32_t col,
                               int32_t cols, int32_t maxLines, int32_t draw) {
    char line[224];
    int32_t used = 0;
    int32_t i = 0;
    if (cols > (int32_t)sizeof(line) - 1) cols = (int32_t)sizeof(line) - 1;
    while (s[i] && used < maxLines) {
        int32_t take = 0, brk = -1, j;
        for (j = 0; j < cols && s[i + j] && s[i + j] != '\n'; j++)
            if (s[i + j] == ' ') brk = j;
        take = j;
        if (s[i + j] && s[i + j] != '\n' && brk > 0) take = brk;
        memcpy(line, s + i, (size_t)take);
        line[take] = 0;
        /* Say when there is more. `aowl_ov_textn` marks a truncated line with
         * `..` and this did not, so a paragraph that ran past `maxLines` simply
         * stopped mid-sentence and read as the whole thing.
         *
         * It matters here more than anywhere else in the file: every string
         * this wraps is the *manager's* -- a decision's `reason`, a list's
         * `description`, the sentence `managerContradiction()` writes, which is
         * three hundred characters and would lose its second half. The claim
         * this panel makes is that it prints what the manager said; a silent
         * truncation is that claim quietly failing, and the reader has no way
         * to tell which sentences they are getting all of. */
        {
            int32_t rest = i + take;
            while (s[rest] == ' ' || s[rest] == '\n') rest++;
            if (used == maxLines - 1 && s[rest]) {
                if (take + 2 <= (int32_t)sizeof(line) - 1 && take + 2 <= cols) {
                    line[take] = '.'; line[take + 1] = '.'; line[take + 2] = 0;
                } else if (take >= 2) {
                    line[take - 1] = '.'; line[take - 2] = '.';
                }
            }
        }
        if (draw) aowl_ov_text(x, y + (float)(used * AOWL_OV_LINE_H), line, col);
        used++;
        i += take;
        while (s[i] == ' ') i++;
        if (s[i] == '\n') i++;
    }
    return used;
}

static int32_t aowl_ov_wrap(float x, float y, const char* s, uint32_t col,
                            int32_t cols, int32_t maxLines) {
    return aowl_ov_wrap_ex(x, y, s, col, cols, maxLines, 1);
}

/* How many lines the same text would take. Nothing is drawn and nothing is
 * measured a second way: it is `aowl_ov_wrap` with its one `aowl_ov_text` call
 * switched off. */
static int32_t aowl_ov_wrap_lines(const char* s, int32_t cols, int32_t maxLines) {
    return aowl_ov_wrap_ex(0.0f, 0.0f, s, 0u, cols, maxLines, 0);
}

/* ------------------------------------------------------------------ *
 * The snapshot
 *
 * The render thread draws from its own copy, taken under the lock and only
 * when the worker says something moved. On a frame where nothing changed --
 * which is fifty-nine frames in sixty -- this costs one integer compare, and
 * the lock is not taken at all.
 * ------------------------------------------------------------------ */

static void aowl_ov_snapshot(void) {
    if (g_ov.snapSerial == g_ov.dataSerial) return;
    EnterCriticalSection(&g_ov.cs);
    g_ov.snapSerial = g_ov.dataSerial;
    g_ov.sModCount = g_ov.modCount;
    memcpy(g_ov.sMods, g_ov.mods, sizeof(AowlOvMod) * (size_t)g_ov.modCount);
    g_ov.sListCount = g_ov.listCount;
    memcpy(g_ov.sLists, g_ov.lists, sizeof(AowlOvList) * (size_t)g_ov.listCount);
    g_ov.sEntryCount = g_ov.entryCount;
    memcpy(g_ov.sEntries, g_ov.entries, sizeof(AowlOvEntry) * (size_t)g_ov.entryCount);
    g_ov.sIssueCount = g_ov.issueCount;
    memcpy(g_ov.sIssues, g_ov.issues, sizeof(AowlOvIssue) * (size_t)g_ov.issueCount);
    g_ov.sResultCount = g_ov.resultCount;
    memcpy(g_ov.sResults, g_ov.results, sizeof(AowlOvResult) * (size_t)g_ov.resultCount);
    memcpy(g_ov.sControl, g_ov.control, sizeof(g_ov.control));
    memcpy(g_ov.sSide, g_ov.side, sizeof(g_ov.side));
    memcpy(g_ov.sSummary, g_ov.summary, sizeof(g_ov.summary));
    memcpy(g_ov.sActiveLists, g_ov.activeLists, sizeof(g_ov.activeLists));
    memcpy(g_ov.sInEffect, g_ov.inEffect, sizeof(g_ov.inEffect));
    memcpy(g_ov.sApplyNote, g_ov.applyNote, sizeof(g_ov.applyNote));
    memcpy(g_ov.sApplyWhat, g_ov.applyWhat, sizeof(g_ov.applyWhat));
    memcpy(g_ov.sApplyControl, g_ov.applyControl, sizeof(g_ov.applyControl));
    memcpy(g_ov.sLastError, g_ov.lastError, sizeof(g_ov.lastError));
    g_ov.sApplyRequested = g_ov.applyRequested;
    g_ov.sApplyDeferred = g_ov.applyDeferred;
    g_ov.sApplyRestart = g_ov.applyRestart;
    g_ov.sLiveKnownAll = g_ov.liveKnownAll;
    g_ov.sClientHost = g_ov.clientHost;
    g_ov.sClientSeq = g_ov.clientSeq;
    g_ov.sClientRows = g_ov.clientRows;
    g_ov.sClientMore = g_ov.clientMore;
    memcpy(g_ov.sClientSession, g_ov.clientSession, sizeof(g_ov.clientSession));

    /* The settings screen's two tables, same copy-under-lock discipline. */
    g_ov.sPageCount = g_ov.pageCount;
    memcpy(g_ov.sPages, g_ov.pages, sizeof(AowlOvSPage) * (size_t)g_ov.pageCount);
    g_ov.sItemCount = g_ov.itemCount;
    memcpy(g_ov.sItems, g_ov.items, sizeof(AowlOvSItem) * (size_t)g_ov.itemCount);
    memcpy(g_ov.sItemsPage, g_ov.itemsPage, sizeof(g_ov.sItemsPage));
    g_ov.sItemsErr = g_ov.itemsErr;
    memcpy(g_ov.sCats, g_ov.cats, sizeof(AowlOvSCat) * (size_t)g_ov.catCount);
    g_ov.sCatCount = g_ov.catCount;
    memcpy(g_ov.sItemsWhy, g_ov.itemsWhy, sizeof(g_ov.sItemsWhy));
    memcpy(g_ov.sWriteWhy, g_ov.writeWhy, sizeof(g_ov.sWriteWhy));
    memcpy(g_ov.sIdxWhy, g_ov.idxWhy, sizeof(g_ov.sIdxWhy));
    g_ov.sItemsImpl = g_ov.itemsImpl;
    g_ov.sHiddenCount = g_ov.hiddenCount;
    LeaveCriticalSection(&g_ov.cs);
}

/* ------------------------------------------------------------------ *
 * Filtering
 * ------------------------------------------------------------------ */

static const char* aowl_ov_filter_name(int32_t f) {
    if (f == AOWL_FILTER_LOADING) return "loading";
    if (f == AOWL_FILTER_EXCLUDED) return "not loading";
    if (f == AOWL_FILTER_OVERRIDDEN) return "yours";
    return "all";
}

static int32_t aowl_ov_passes(const AowlOvMod* m, int32_t f) {
    if (f == AOWL_FILTER_LOADING) return m->enabled != 0;
    if (f == AOWL_FILTER_EXCLUDED) return m->enabled == 0;
    if (f == AOWL_FILTER_OVERRIDDEN) return m->explicitOv != 0;
    return 1;
}

/* The visible rows of the mods view, as indices into the snapshot. Rebuilt
 * every frame because it is 64 compares and keeping it in sync with the filter
 * and the poll would cost more than recomputing it. */
static int32_t aowl_ov_visible_rows(int32_t* out) {
    int32_t n = 0, i;
    for (i = 0; i < g_ov.sModCount; i++)
        if (aowl_ov_passes(&g_ov.sMods[i], g_ov.filter)) out[n++] = i;
    return n;
}

/* ------------------------------------------------------------------ *
 * Actions
 *
 * Each one is a request the manager already serves. The overlay changes no
 * state of its own beyond marking a row `pending`, which is what draws the `~`
 * -- so a gesture that the backend never answers stays visibly unfinished
 * instead of looking done.
 * ------------------------------------------------------------------ */

/* Whether the manager has said it will refuse to switch this row off.
 *
 * This used to be a literal `"aowl.manager"` compared with `strcmp`, and it was
 * marked in this file as a stopgap for exactly the reason it has stopped being
 * one: a header that hardcodes the manager's name is a header that has to be
 * edited when the manager is renamed, and it could only ever protect the one
 * mod somebody thought of. `mods/manager` now answers `protected` on every
 * panel row and enforces it at all three doors -- `routeDisable`,
 * `routeToggle`, and `applySelection`, which skips the unload even when the
 * selection store was hand-edited or a registry's lists simply stopped naming
 * the mod. So the rule is the manager's property and this is a lookup.
 *
 * Which mods are protected is therefore not this file's business, and that is
 * the point: when the rule grows to cover a second mod, nothing here changes.
 *
 * Not in the table at all counts as not protected. A guid the manager has never
 * mentioned is one the client host pushed in, and the manager would refuse the
 * toggle on the grounds that it has never heard of it -- which is a different
 * refusal, with its own sentence, and one worth letting it make. */
static int32_t aowl_ov_protected(const char* guid) {
    int32_t i;
    for (i = 0; i < g_ov.sModCount; i++)
        if (strcmp(g_ov.sMods[i].guid, guid) == 0) return g_ov.sMods[i].protectedRow;
    return 0;
}

static void aowl_ov_act_toggle(const char* guid) {
    int32_t k;
    int32_t want = 0;

    /* Read-only: say so and change nothing. Flipping the row first and marking
     * it `pending` would leave a `~` that nothing can ever clear. */
    if (g_ov.backendPort <= 0) {
        aowl_ov_queue_cmd(AOWL_CMD_TOGGLE, guid, 0);   /* refuses, and explains */
        return;
    }

    /* Refused here rather than sent, and only in the direction that is
     * refused: the manager turns down a protected mod being switched *off* and
     * takes `{"enabled":true}` on it like any other row, so a protected row
     * that is somehow off must still be switchable back on.
     *
     * Locally, because a round trip to be told no is a row that sits at `~` for
     * a second before nothing happens. The manager refuses it too, in its own
     * fuller words -- this is the panel agreeing with it, not the panel being
     * the only thing stopping it. */
    {
        int32_t on = 0, found = 0, i;
        for (i = 0; i < g_ov.sModCount; i++)
            if (strcmp(g_ov.sMods[i].guid, guid) == 0) {
                on = g_ov.sMods[i].enabled;
                found = 1;
                break;
            }
        if (found && on && aowl_ov_protected(guid)) {
            EnterCriticalSection(&g_ov.cs);
            aowl_ov_copy(g_ov.lastError, (int32_t)sizeof(g_ov.lastError),
                         "the manager marks this mod protected and will not "
                         "switch it off: it is what serves this panel, and "
                         "nothing running could switch it back on. Take it out "
                         "of the install if you mean it.");
            aowl_ov_fmt(g_ov.applyWhat, (int32_t)sizeof(g_ov.applyWhat),
                        "refused: disable %s (protected)", guid);
            g_ov.resultCount = 0;
            LeaveCriticalSection(&g_ov.cs);
            g_ov.dataSerial++;
            return;
        }
    }

    EnterCriticalSection(&g_ov.cs);
    for (k = 0; k < g_ov.modCount; k++) {
        if (strcmp(g_ov.mods[k].guid, guid) == 0) {
            g_ov.mods[k].enabled = !g_ov.mods[k].enabled;
            g_ov.mods[k].pending = 1;
            want = g_ov.mods[k].enabled;
            break;
        }
    }
    LeaveCriticalSection(&g_ov.cs);
    if (k < g_ov.modCount) {
        g_ov.dataSerial++;
        aowl_ov_queue_cmd(AOWL_CMD_TOGGLE, guid, want);
    }
}

static void aowl_ov_act_clear(const char* guid) {
    int32_t k;
    if (g_ov.backendPort <= 0) {
        aowl_ov_queue_cmd(AOWL_CMD_CLEAR, guid, 0);
        return;
    }
    EnterCriticalSection(&g_ov.cs);
    for (k = 0; k < g_ov.modCount; k++)
        if (strcmp(g_ov.mods[k].guid, guid) == 0) { g_ov.mods[k].pending = 1; break; }
    LeaveCriticalSection(&g_ov.cs);
    g_ov.dataSerial++;
    aowl_ov_queue_cmd(AOWL_CMD_CLEAR, guid, 0);
}

/* ------------------------------------------------------------------ *
 * The keyboard
 * ------------------------------------------------------------------ */

static void aowl_ov_push_key(LONG vk) {
    LONG h = g_ov.keyHead;
    LONG next = (h + 1) & (AOWL_OV_KEYS - 1);
    if (next == g_ov.keyTail) return;       /* full: the oldest wins */
    g_ov.keys[h] = vk;
    InterlockedExchange(&g_ov.keyHead, next);
}

static int32_t aowl_ov_pop_key(LONG* vk) {
    LONG t = g_ov.keyTail;
    if (t == g_ov.keyHead) return 0;
    *vk = g_ov.keys[t];
    InterlockedExchange(&g_ov.keyTail, (t + 1) & (AOWL_OV_KEYS - 1));
    return 1;
}

/* How many rows the current view has, for the cursor to move within. */
static int32_t aowl_ov_row_count(int32_t view, const int32_t* vis, int32_t visN) {
    (void)vis;
    if (view == AOWL_VIEW_MODS) return visN;
    if (view == AOWL_VIEW_LISTS) return g_ov.sListCount;
    if (view == AOWL_VIEW_ISSUES) return g_ov.sIssueCount;
    /* The FILTERED count, not the held count: the cursor moves through what is
     * on screen, and a count that included hidden lines would let END land on
     * a row that is not drawn. */
    if (view == AOWL_VIEW_LOGS) return g_ov.logFiltN;
    return g_ov.sResultCount;
}

static void aowl_ov_move(int32_t view, int32_t delta, int32_t count) {
    int32_t s = g_ov.sel[view] + delta;
    if (count <= 0) { g_ov.sel[view] = 0; return; }
    if (s < 0) s = 0;
    if (s >= count) s = count - 1;
    g_ov.sel[view] = s;
}

/* Defined below, next to the settings screen it drives. */
static void aowl_ov_settings_key(LONG vk, int32_t page);
/* Both defined with the settings screen below; F2 and F8 are handled up here,
 * before the mode branch, so that they work from either face of the panel. */
static void aowl_ov_s_flush_now(void);
static void aowl_ov_rebuild_pages(void);
static int32_t aowl_ov_searching(void);
static char aowl_ov_vk_char(LONG vk);
/* The LOGS view's own key handler and its focus flag, both defined with the
 * screen below. Declared here for the same reason the settings pair is: the
 * key pump is above the screens it drives. */
static int32_t aowl_ov_logs_key(LONG vk, int32_t page, int32_t count);
static int32_t aowl_ov_log_searching(void);

/* Drains the ring and turns it into actions. Runs on the render thread, once
 * per frame, so a key pressed between two frames is never lost and a key held
 * down repeats at the OS repeat rate rather than at the frame rate. `page` is
 * how far PgUp/PgDn moves, which depends on how tall the panel came out. */
static void aowl_ov_keys(int32_t page, const int32_t* vis, int32_t visN) {
    LONG vk;
    while (aowl_ov_pop_key(&vk)) {
        int32_t view = g_ov.view;
        int32_t count = aowl_ov_row_count(view, vis, visN);

        /* F2 flips between the mod manager and the settings screen, in either
         * direction, and any in-progress edit is dropped rather than carried
         * across. It is checked before the mode branch so it works from both. */
        if (vk == VK_F2) {
            /* A held write is SENT, not dropped. Switching face is not undo:
             * the row on screen already shows the new value and the file must
             * agree with it. Only the in-progress TEXT edit -- which the player
             * has not confirmed with ENTER -- is abandoned. */
            aowl_ov_s_flush_now();
            g_ov.settings = !g_ov.settings;
            g_ov.editItem = -1; g_ov.capturing = 0; g_ov.dragItem = -1;
            continue;
        }

        /* F8 -- SHOW THE SETTINGS THAT ARE NOT IMPLEMENTED YET. Default OFF.
         *
         * A developer needs to see them; a beta tester must not be handed a
         * screen of controls that do nothing, which is what "simply dont show
         * the not included or finished stuff" asked for. It is a function key
         * for the same reason every other panel shortcut is: no text field can
         * eat it, so it works with the search box focused and with a value box
         * open.
         *
         * The flag is read by the PARSER, so flipping it has to re-parse. The
         * page is dropped by clearing `curPage`, which the draw sees as "the
         * cursor is on a page that is not loaded" and re-requests through the
         * ordinary path -- there is no second load route to keep in step. */
        if (vk == VK_F8) {
            aowl_ov_s_flush_now();
            EnterCriticalSection(&g_ov.cs);
            g_ov.showUnimpl = !g_ov.showUnimpl;
            aowl_ov_rebuild_pages();
            g_ov.itemsPage[0] = 0;
            g_ov.dataSerial++;
            LeaveCriticalSection(&g_ov.cs);
            g_ov.curPage[0] = 0;
            g_ov.editItem = -1; g_ov.capturing = 0; g_ov.dragItem = -1;
            g_ov.selCat = -1; g_ov.selItem = 0; g_ov.topItem = 0;
            g_ov.filtStamp = 0;
            continue;
        }

        /* --- THE INPUT MODEL, stated once and obeyed everywhere -----------
         *
         * The rule the panel now follows, and the one the footer prints:
         *
         *   * THE SEARCH FIELD ONLY HAS FOCUS AFTER `/` OR A CLICK ON IT.
         *     It is permanently VISIBLE; that is not the same as permanently
         *     focused, and conflating the two is what broke this. While it has
         *     focus it takes every printable key, which is what a text field
         *     must do -- so `-` and `=` reached it and never reached the panel,
         *     and the shortcuts the legend advertised were unreachable. That
         *     was the bug.
         *   * ESC gives the keyboard back to the list (and clears the term).
         *     ENTER, TAB and DOWN give it back and KEEP the term.
         *   * FUNCTION KEYS ARE NEVER SWALLOWED. F9/F10/F11 work whatever has
         *     focus, because they are not printable and so can never be
         *     something the player meant to type. That is why the opacity
         *     control is F9/F10 and not only `-`/`=`.
         *
         *     ...which is necessary and was not SUFFICIENT: F10 is also
         *     Windows' menu key and arrives as WM_SYSKEYDOWN, a message the
         *     panel's own switch did not take. "Not swallowed by a text field"
         *     and "delivered to the panel at all" are two different claims and
         *     only the first was true. See WM_SYSKEYDOWN in the wndproc.
         *   * `-`/`=` remain as aliases, and work whenever the field does NOT
         *     have focus -- which is the state the panel is in unless the
         *     player put it in the other one on purpose.
         *
         * A shortcut that a text field can eat is not a shortcut, and the fix
         * is not "be cleverer about focus", it is "have keys that cannot be
         * typed". */
        if (vk == VK_F11) {
            g_ov.panMax = !g_ov.panMax;
            InterlockedExchange(&g_ov.prefsDirty, 1);
            continue;
        }
        if (vk == VK_F9 || vk == VK_F10) {
            g_ov.panAlpha += (vk == VK_F10) ? 27 : -27;
            if (g_ov.panAlpha < 40) g_ov.panAlpha = 40;
            if (g_ov.panAlpha > 255) g_ov.panAlpha = 255;
            InterlockedExchange(&g_ov.prefsDirty, 1);
            continue;
        }
        /* The alias keys are live UNLESS a text field on the current screen
         * has the keyboard -- the settings search box, or the logs one. The
         * fix for `-`/`=` being eaten was never "no text fields"; it was
         * "shortcuts a text field cannot eat" (the F-keys above) plus this
         * one narrow exception, and a second screen with a search box has to
         * be named here or it reintroduces exactly that bug. */
        if (!((g_ov.settings && g_ov.searchFocus) ||
              (!g_ov.settings && g_ov.view == AOWL_VIEW_LOGS &&
               aowl_ov_log_searching()))) {
            if (vk == VK_OEM_MINUS || vk == VK_SUBTRACT) {
                g_ov.panAlpha -= 27;
                if (g_ov.panAlpha < 40) g_ov.panAlpha = 40;
                InterlockedExchange(&g_ov.prefsDirty, 1);
                continue;
            }
            if (vk == VK_OEM_PLUS || vk == VK_ADD) {
                g_ov.panAlpha += 27;
                if (g_ov.panAlpha > 255) g_ov.panAlpha = 255;
                InterlockedExchange(&g_ov.prefsDirty, 1);
                continue;
            }
        }

        if (g_ov.settings) { aowl_ov_settings_key(vk, page); continue; }

        /* The logs screen gets first refusal, so its search box can own TAB
         * and the arrows while it has focus. It returns 0 for anything it does
         * not claim, and everything below then behaves exactly as it did. */
        if (view == AOWL_VIEW_LOGS && aowl_ov_logs_key(vk, page, count))
            continue;

        if (vk == VK_TAB || vk == VK_RIGHT) {
            g_ov.view = (view + 1) % AOWL_VIEW_COUNT;
            continue;
        }
        if (vk == VK_LEFT) {
            g_ov.view = (view + AOWL_VIEW_COUNT - 1) % AOWL_VIEW_COUNT;
            continue;
        }
        if (vk >= '1' && vk <= '5') { g_ov.view = (int32_t)(vk - '1'); continue; }
        if (vk == VK_UP   || vk == 'W') { aowl_ov_move(view, -1, count); continue; }
        if (vk == VK_DOWN || vk == 'S') { aowl_ov_move(view, +1, count); continue; }
        if (vk == VK_PRIOR) { aowl_ov_move(view, -page, count); continue; }
        if (vk == VK_NEXT)  { aowl_ov_move(view, +page, count); continue; }
        if (vk == VK_HOME)  { g_ov.sel[view] = 0; continue; }
        if (vk == VK_END)   { g_ov.sel[view] = count > 0 ? count - 1 : 0; continue; }

        if (vk == 'F' && view == AOWL_VIEW_MODS) {
            g_ov.filter = (g_ov.filter + 1) % AOWL_FILTER_COUNT;
            g_ov.sel[view] = 0;
            g_ov.top[view] = 0;
            continue;
        }
        if (vk == VK_SPACE || vk == VK_RETURN) {
            if (view == AOWL_VIEW_MODS && visN > 0 && g_ov.sel[view] < visN)
                aowl_ov_act_toggle(g_ov.sMods[vis[g_ov.sel[view]]].guid);
            else if (view == AOWL_VIEW_LISTS && g_ov.sel[view] < g_ov.sListCount)
                aowl_ov_queue_cmd(AOWL_CMD_SELECT,
                                  g_ov.sLists[g_ov.sel[view]].id, 0);
            continue;
        }
        if (vk == 'C') {
            if (view == AOWL_VIEW_MODS && visN > 0 && g_ov.sel[view] < visN)
                aowl_ov_act_clear(g_ov.sMods[vis[g_ov.sel[view]]].guid);
            continue;
        }
        if (vk == 'A') { aowl_ov_queue_cmd(AOWL_CMD_APPLY, "", 0); g_ov.view = AOWL_VIEW_APPLY; continue; }
        if (vk == 'R') { aowl_ov_queue_cmd(AOWL_CMD_RELOAD, "", 0); continue; }
    }
}

/* ------------------------------------------------------------------ *
 * Chrome
 * ------------------------------------------------------------------ */

/* The one line that says whether anything on this panel can be trusted. Four
 * states and they are not interchangeable:
 *
 *   no port      the host started the overlay without a backend. The rows are
 *                whatever the client host pushed in, which is what is running
 *                in this process, and nothing here can be changed.
 *   waiting      a port, and nothing has ever answered on it.
 *   up           an answer arrived within the last few seconds.
 *   stale        it answered once and has stopped. The age is printed, because
 *                "the backend went away eleven seconds ago" and "the backend
 *                has never been there" are different problems.
 */
static void aowl_ov_health(char* out, int32_t cap, uint32_t* col) {
    if (g_ov.backendPort <= 0) {
        aowl_ov_fmt(out, cap, "no backend (read-only)");
        *col = AOWL_OV_DIM;
        return;
    }
    if (g_ov.backendOk) {
        aowl_ov_fmt(out, cap, "backend :%d  %dms%s", g_ov.backendPort,
                    g_ov.dispRttMs, g_ov.busy ? " ..." : "");
        *col = AOWL_OV_GOOD;
        return;
    }
    if (!g_ov.everOk) {
        aowl_ov_fmt(out, cap, "backend :%d not answering%s", g_ov.backendPort,
                    g_ov.busy ? " ..." : "");
        *col = AOWL_OV_ERR;
        return;
    }
    aowl_ov_fmt(out, cap, "backend :%d stale %ds", g_ov.backendPort,
                g_ov.dispStaleS);
    *col = AOWL_OV_WARN;
}

/* `counts` is sized by the enum rather than by a literal 4 -- it was `[4]`,
 * which a fifth view would have overrun silently. */
static void aowl_ov_tabs(float x, float y, float w,
                         int32_t counts[AOWL_VIEW_COUNT]) {
    static const char* names[AOWL_VIEW_COUNT] = { "MODS", "LISTS", "ISSUES",
                                                  "APPLY", "LOGS" };
    float tx = x + AOWL_OV_PAD;
    int32_t i;
    aowl_ov_rect(x + 1.0f, y, w - 2.0f, (float)AOWL_OV_TABS_H, AOWL_OV_PANEBG);
    for (i = 0; i < AOWL_VIEW_COUNT; i++) {
        char lab[32];
        float tw;
        int32_t hot;
        aowl_ov_fmt(lab, sizeof(lab), " %s %d ", names[i], counts[i]);
        tw = (float)(strlen(lab) * AOWL_OV_CW);
        hot = aowl_ov_hit(tx, y, tw, (float)AOWL_OV_TABS_H);
        if (i == g_ov.view)
            aowl_ov_rect(tx, y, tw, (float)AOWL_OV_TABS_H, AOWL_OV_SELBG);
        else if (hot)
            aowl_ov_rect(tx, y, tw, (float)AOWL_OV_TABS_H, AOWL_OV_HOT);
        aowl_ov_text(tx, y + 3.0f, lab,
                     i == g_ov.view ? AOWL_OV_TEXT : AOWL_OV_DIM);
        /* A tab is the one thing worth clicking: it is a big target and it is
         * the gesture a player reaches for before they have read the legend. */
        if (hot && g_ov.clickDown) { g_ov.view = i; InterlockedExchange(&g_ov.clickDown, 0); }
        tx += tw + 6.0f;
    }
    /* The number of issues is the one count that has to be visible from the
     * other three views, so it is coloured rather than merely printed. */
    if (counts[AOWL_VIEW_ISSUES] > 0) {
        char warn[48];
        float ww;
        aowl_ov_fmt(warn, sizeof(warn), "%d problem%s", counts[AOWL_VIEW_ISSUES],
                    counts[AOWL_VIEW_ISSUES] == 1 ? "" : "s");
        ww = (float)(strlen(warn) * AOWL_OV_CW);
        aowl_ov_text(x + w - AOWL_OV_PAD - ww, y + 3.0f, warn, AOWL_OV_WARN);
    }
}

/* ------------------------------------------------------------------ *
 * "Is it running", said out loud
 *
 * Three functions, and between them they are the whole of the rule that
 * absence is not a negative. Every one of them has a case for "nobody has
 * said", none of them can be persuaded to print "no" without a source, and the
 * pane below calls them rather than composing a sentence inline -- which is how
 * the last version of this ended up drawing `running yes` about a mod the host
 * had unloaded.
 * ------------------------------------------------------------------ */

/* The `running` word on the detail line: what this panel actually knows. */
static const char* aowl_ov_run_word(const AowlOvMod* m) {
    if (m->hostPushed || m->liveKnown || m->clientKnown)
        return m->loaded ? "yes" : "no";
    return "unknown";
}

/* The sentence behind a `clientCode` slug. The closed set is
 * `host/common/modcontrol.nim`'s and the wording is `clientMessage`'s in
 * `mgr/clientreport.nim` -- said again here rather than read off the row
 * because the manager appends it to `reason`, and `reason` is a 160-byte field
 * that the resolver's own sentence has usually already filled.
 *
 * A slug this does not know returns "" and is printed bare. A panel that
 * invented an explanation for a code from a newer host would be putting that
 * host's words in its own mouth. */
static const char* aowl_ov_client_why(const char* code) {
    if (!code[0]) return "";
    if (strcmp(code, "noartifact") == 0)
        return "the registry gives it no artifact to load";
    if (strcmp(code, "nofile") == 0)
        return "it is not installed on the client side";
    if (strcmp(code, "nopath") == 0)
        return "the client host was given no path to load it from";
    if (strcmp(code, "missing") == 0)
        return "the client loader reported success and left no live mod behind";
    if (strcmp(code, "wrongguid") == 0)
        return "that library announces a different guid";
    if (strcmp(code, "loadfailed") == 0)
        return "the client loader refused it; the host log has the reason";
    if (strcmp(code, "noteardown") == 0)
        return "that host cannot take any mod out while it runs";
    if (strcmp(code, "unloadfailed") == 0)
        return "the unload itself failed; the host log has the reason";
    return "";
}

/* One line about the game's own host, for the selected row. Writes `buf` and
 * sets `*col`; always writes something, because "the panel said nothing about
 * the client" is indistinguishable from "the client said nothing" and only one
 * of those is true at a time.
 *
 * The three unknowns are kept apart on purpose. `clientMore` is a rotation that
 * has not reached this row yet and *will*; a complete report that does not
 * mention it is a mod that side is not being asked about at all; and no report
 * ever is usually no game running. Told they are all "unknown" and nothing
 * else, a player cannot tell "wait a second" from "your game is not up". */
static void aowl_ov_client_line(const AowlOvMod* m, char* buf, int32_t cap,
                                uint32_t* col) {
    if (m->clientKnown) {
        const char* why = aowl_ov_client_why(m->clientCode);
        const char* out = m->clientOutcome[0] ? m->clientOutcome : "?";
        *col = m->clientLive != m->clientWant ? AOWL_OV_WARN
             : m->clientLive ? AOWL_OV_GOOD : AOWL_OV_DIM;
        if (m->clientCode[0] && why[0])
            aowl_ov_fmt(buf, cap,
                        "in the game: %s   the client host wanted it %s and "
                        "says %s [%s] -- %s",
                        m->clientLive ? "running" : "not running",
                        m->clientWant ? "on" : "off", out, m->clientCode, why);
        else if (m->clientCode[0])
            aowl_ov_fmt(buf, cap,
                        "in the game: %s   the client host wanted it %s and "
                        "says %s [%s]",
                        m->clientLive ? "running" : "not running",
                        m->clientWant ? "on" : "off", out, m->clientCode);
        else
            aowl_ov_fmt(buf, cap,
                        "in the game: %s   the client host wanted it %s and "
                        "says %s",
                        m->clientLive ? "running" : "not running",
                        m->clientWant ? "on" : "off", out);
        return;
    }
    *col = AOWL_OV_FAINT;
    if (!g_ov.sClientHost) {
        /* Worth being exact about, because the obvious wording is wrong: this
         * panel is drawn *inside* the game, so "no game is running" is never
         * the explanation. `clientHost:false` means the host in this process
         * has not reported to the manager -- it has not polled yet, or it is a
         * build from before the report existed. That is also why the overlay
         * does not poll `/aowlspt/mods/clientreport` for `silentPolls`: the
         * question it would answer is one the overlay's own existence already
         * answers. */
        aowl_ov_fmt(buf, cap,
                    "in the game: unknown -- the client host in this process "
                    "has not reported to the manager, so nothing has been said "
                    "about this mod either way. Not the same as `not running`.");
    } else if (g_ov.sClientMore) {
        aowl_ov_fmt(buf, cap,
                    "in the game: unknown -- the client host is reporting in "
                    "instalments (%d row%s so far) and this one has not arrived "
                    "yet; it will on a later poll",
                    g_ov.sClientRows, g_ov.sClientRows == 1 ? "" : "s");
    } else {
        aowl_ov_fmt(buf, cap,
                    "in the game: unknown -- the client host reported all %d of "
                    "its row%s and none of them was this mod; it may not run on "
                    "that side at all",
                    g_ov.sClientRows, g_ov.sClientRows == 1 ? "" : "s");
    }
}

/* ------------------------------------------------------------------ *
 * The views
 * ------------------------------------------------------------------ */

static void aowl_ov_view_mods(float x, float y, float w, float bodyH,
                              const int32_t* vis, int32_t visN, int32_t rows) {
    int32_t i;
    int32_t sel = g_ov.sel[AOWL_VIEW_MODS];
    float ry = y;
    int32_t cols = (int32_t)(w / AOWL_OV_CW);
    /* Column origins in pixels from the panel's left padding. Fixed rather than
     * proportional: a monospaced 8x16 cell means a column that moves with the
     * window is a column that stops lining up with its heading. */
    const float cName = 26.0f, cVer = 250.0f, cVerdict = 330.0f, cFrom = 490.0f;

    if (g_ov.top[AOWL_VIEW_MODS] > sel) g_ov.top[AOWL_VIEW_MODS] = sel;
    if (sel - g_ov.top[AOWL_VIEW_MODS] >= rows)
        g_ov.top[AOWL_VIEW_MODS] = sel - rows + 1;
    if (g_ov.top[AOWL_VIEW_MODS] > visN - rows) g_ov.top[AOWL_VIEW_MODS] = visN - rows;
    if (g_ov.top[AOWL_VIEW_MODS] < 0) g_ov.top[AOWL_VIEW_MODS] = 0;

    /* Headings, so the columns are named rather than guessed at. */
    aowl_ov_text(x + AOWL_OV_PAD + cName, ry, "mod", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + cVer, ry, "version", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + cVerdict, ry, "verdict", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + cFrom, ry, "decided by", AOWL_OV_FAINT);
    ry += (float)AOWL_OV_LINE_H;

    if (visN == 0) {
        const char* why = (g_ov.sModCount == 0)
            ? (g_ov.backendPort > 0
                 ? "no rows yet -- the backend has not answered, and the client "
                   "host pushed nothing in"
                 : "no rows -- there is no backend and the client host pushed "
                   "nothing in")
            : "no mod matches this filter; press F to widen it";
        aowl_ov_wrap(x + AOWL_OV_PAD, ry, why, AOWL_OV_DIM, cols - 3, 2);
    }

    for (i = 0; i < rows && g_ov.top[AOWL_VIEW_MODS] + i < visN; i++) {
        int32_t at = vis[g_ov.top[AOWL_VIEW_MODS] + i];
        AowlOvMod* m = &g_ov.sMods[at];
        float by, bh, bx;
        int32_t hot;
        int32_t isSel = (g_ov.top[AOWL_VIEW_MODS] + i) == sel;
        char mark[4];
        const char* label;
        uint32_t nameCol;

        if (isSel) aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                                (float)AOWL_OV_ROW_H, AOWL_OV_SELBG);
        else if (i & 1) aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                                     (float)AOWL_OV_ROW_H, AOWL_OV_ROWALT);

        /* `*` is your override -- the one thing on the row that you did rather
         * than a list, and the one thing `C` can undo. `!` is the game
         * disagreeing with the switch beside it: the client host has answered
         * about this guid and what it answered is not what was asked for. Only
         * ever drawn from a record -- a row the client host has said nothing
         * about carries no mark, because silence is not a disagreement and a
         * panel that marked it would put a `!` on every client mod the moment a
         * report arrived in instalments. */
        mark[0] = m->explicitOv ? '*' : ' ';
        mark[1] = m->pending ? '~'
                : (m->clientKnown && m->clientLive != m->clientWant) ? '!' : ' ';
        mark[2] = 0;
        aowl_ov_text(x + AOWL_OV_PAD, ry + 3.0f, mark,
                     m->pending ? AOWL_OV_WARN
                     : (m->clientKnown && m->clientLive != m->clientWant)
                         ? AOWL_OV_ERR : AOWL_OV_ACCENT);

        /* Dim means "not running". With no host answering the control probe
         * `live` is null for every row and nothing is dimmed on that account --
         * which is correct: nobody knows, so nothing may be greyed. */
        nameCol = m->loaded ? AOWL_OV_TEXT : (m->enabled ? AOWL_OV_TEXT : AOWL_OV_DIM);
        aowl_ov_textn(x + AOWL_OV_PAD + cName, ry + 3.0f,
                      m->name[0] ? m->name : m->guid, nameCol, 27);
        aowl_ov_textn(x + AOWL_OV_PAD + cVer, ry + 3.0f, m->version, AOWL_OV_DIM, 9);
        aowl_ov_textn(x + AOWL_OV_PAD + cVerdict, ry + 3.0f,
                      m->verdict[0] ? m->verdict : "-",
                      (strcmp(m->verdict, "loaded") == 0) ? AOWL_OV_GOOD
                      : (m->verdict[0] && strcmp(m->verdict, "disabled") != 0 &&
                         strcmp(m->verdict, "not-selected") != 0) ? AOWL_OV_WARN
                      : AOWL_OV_DIM, 19);
        aowl_ov_textn(x + AOWL_OV_PAD + cFrom, ry + 3.0f,
                      m->hostPushed && !m->backendRow ? "client host"
                      : m->from[0] ? m->from : "-", AOWL_OV_DIM, 22);

        bx = x + w + AOWL_OV_PAD * 2 - AOWL_OV_PAD - (float)AOWL_OV_BTN_W;
        by = ry + 2.0f;
        bh = (float)(AOWL_OV_ROW_H - 4);
        /* A protected row gets a label rather than a button -- the manager has
         * said it will not switch this one off, and a button that cannot do
         * what the button beside it does should not look like it. It is drawn
         * from the row's own `protected` flag, so whichever mods the manager
         * protects are the ones that show `KEEP`.
         *
         * Only while it is on: a protected mod that is somehow off is a mod you
         * need to be able to switch back on, and the manager allows that. */
        /* The row is still *selectable* -- it just has no button. The earlier
         * version `continue`d here, which skipped the row-select hit test
         * below as well, so clicking a protected row did nothing at all: no
         * detail pane, no `reason`, no `from`. With the shipped registry
         * `aowl.manager` is row zero, which made the first row anybody clicks
         * the one row the mouse could not reach. Refusing the *toggle* is the
         * rule; refusing to explain the row is not. */
        if (m->protectedRow && m->enabled) {
            aowl_ov_rect(bx, by, (float)AOWL_OV_BTN_W, bh, AOWL_OV_ROWALT);
            aowl_ov_frame_rect(bx, by, (float)AOWL_OV_BTN_W, bh, 1.0f, AOWL_OV_FAINT);
            aowl_ov_text(bx + 6.0f, by + 1.0f, "KEEP", AOWL_OV_DIM);
            if (g_ov.clickDown &&
                aowl_ov_hit(x + 1.0f, ry, w, (float)AOWL_OV_ROW_H)) {
                g_ov.sel[AOWL_VIEW_MODS] = g_ov.top[AOWL_VIEW_MODS] + i;
                InterlockedExchange(&g_ov.clickDown, 0);
            }
            ry += (float)AOWL_OV_ROW_H;
            continue;
        }
        hot = aowl_ov_hit(bx, by, (float)AOWL_OV_BTN_W, bh);
        aowl_ov_rect(bx, by, (float)AOWL_OV_BTN_W, bh,
                     hot ? AOWL_OV_HOT : (m->enabled ? AOWL_OV_ON : AOWL_OV_OFF));
        aowl_ov_frame_rect(bx, by, (float)AOWL_OV_BTN_W, bh, 1.0f, AOWL_OV_EDGE);
        /* Three states in five characters, and each one means one thing.
         *   ` ON ` / ` OFF`  what the manager resolves this mod to
         *   `~`              asked for; the server has not answered yet
         *   `*`              the manager says it only changes on a restart
         * `~` wins the slot while both are true: an outstanding request is the
         * more recent fact, and the `*` comes back one poll later if the answer
         * was a deferral. */
        label = m->pending ? (m->enabled ? " ON ~" : " OFF~")
              : m->restart ? (m->enabled ? " ON *" : " OFF*")
                           : (m->enabled ? " ON " : " OFF");
        aowl_ov_text(bx + 6.0f, by + 1.0f, label, AOWL_OV_TEXT);

        if (g_ov.clickDown && hot) {
            g_ov.sel[AOWL_VIEW_MODS] = g_ov.top[AOWL_VIEW_MODS] + i;
            InterlockedExchange(&g_ov.clickDown, 0);
            aowl_ov_act_toggle(m->guid);
        } else if (g_ov.clickDown &&
                   aowl_ov_hit(x + 1.0f, ry, w, (float)AOWL_OV_ROW_H)) {
            g_ov.sel[AOWL_VIEW_MODS] = g_ov.top[AOWL_VIEW_MODS] + i;
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        ry += (float)AOWL_OV_ROW_H;
    }

    /* --- the detail pane: why this row is what it is ---------------- */
    {
        float dy = y + bodyH - (float)AOWL_OV_DETAIL_H;
        char line[256];
        aowl_ov_rect(x + 1.0f, dy, w + AOWL_OV_PAD * 2 - 2.0f,
                     (float)AOWL_OV_DETAIL_H, AOWL_OV_PANEBG);
        aowl_ov_rect(x + 1.0f, dy, w + AOWL_OV_PAD * 2 - 2.0f, 1.0f, AOWL_OV_EDGE);
        dy += 4.0f;
        if (visN > 0 && sel < visN) {
            AowlOvMod* m = &g_ov.sMods[vis[sel]];
            int32_t used;
            aowl_ov_fmt(line, sizeof(line), "%s  %s", m->guid,
                        m->version[0] ? m->version : "");
            aowl_ov_textn(x + AOWL_OV_PAD, dy, line, AOWL_OV_ACCENT, cols - 2);
            dy += (float)AOWL_OV_LINE_H;
            /* The manager's sentence, verbatim and wrapped. This is the whole
             * point of the pane: `mgr/resolve.nim` already worked out why, in
             * one place, against the rules in registry/README.md. */
            used = aowl_ov_wrap(x + AOWL_OV_PAD, dy,
                                m->reason[0] ? m->reason : "no reason given",
                                AOWL_OV_TEXT, cols - 3, 2);
            dy += (float)(used * AOWL_OV_LINE_H);
            aowl_ov_fmt(line, sizeof(line),
                        "verdict %s   decided by %s   your override %s   "
                        "running %s   restart %s",
                        m->verdict[0] ? m->verdict : "?",
                        m->hostPushed && !m->backendRow ? "the client host"
                            : m->from[0] ? m->from : "nothing",
                        m->explicitOv ? "yes (C clears it)" : "no",
                        aowl_ov_run_word(m),
                        m->restart ? "yes" : "no");
            aowl_ov_textn(x + AOWL_OV_PAD, dy, line, AOWL_OV_DIM, cols - 2);
            dy += (float)AOWL_OV_LINE_H;
            /* And the game's own host, always -- including, and especially,
             * when it has said nothing. `running` above is this panel's best
             * answer across both sides; this line is the one side a player is
             * actually sitting in front of, and the difference between the two
             * is a mod loaded on the server and not in the game. */
            {
                uint32_t ccol = AOWL_OV_FAINT;
                char cbuf[320];
                aowl_ov_client_line(m, cbuf, (int32_t)sizeof(cbuf), &ccol);
                aowl_ov_wrap(x + AOWL_OV_PAD, dy, cbuf, ccol, cols - 3, 2);
            }
        } else {
            aowl_ov_text(x + AOWL_OV_PAD, dy, "nothing selected", AOWL_OV_DIM);
        }
    }
}

static void aowl_ov_view_lists(float x, float y, float w, float bodyH,
                               int32_t rows) {
    /* Two panes. The left one is what you pick from; the right one is what
     * picking it would mean, which is the question a named list raises and the
     * one a row of names cannot answer. */
    float leftW = 300.0f;
    float rx = x + AOWL_OV_PAD + leftW + 12.0f;
    int32_t rcols = (int32_t)((w + AOWL_OV_PAD * 2 - (rx - x) - AOWL_OV_PAD) / AOWL_OV_CW);
    int32_t sel = g_ov.sel[AOWL_VIEW_LISTS];
    float ry = y;
    int32_t i;

    if (g_ov.top[AOWL_VIEW_LISTS] > sel) g_ov.top[AOWL_VIEW_LISTS] = sel;
    if (sel - g_ov.top[AOWL_VIEW_LISTS] >= rows)
        g_ov.top[AOWL_VIEW_LISTS] = sel - rows + 1;
    if (g_ov.top[AOWL_VIEW_LISTS] < 0) g_ov.top[AOWL_VIEW_LISTS] = 0;

    aowl_ov_text(x + AOWL_OV_PAD, ry, "lists", AOWL_OV_FAINT);
    aowl_ov_text(rx, ry, "what it contains", AOWL_OV_FAINT);
    ry += (float)AOWL_OV_LINE_H;

    if (g_ov.sListCount == 0) {
        aowl_ov_wrap(x + AOWL_OV_PAD, ry,
                     g_ov.backendPort > 0
                       ? "no lists -- /aowlspt/mods/lists has not answered yet"
                       : "no lists -- there is no backend to ask",
                     AOWL_OV_DIM, 34, 3);
    }

    for (i = 0; i < rows && g_ov.top[AOWL_VIEW_LISTS] + i < g_ov.sListCount; i++) {
        int32_t at = g_ov.top[AOWL_VIEW_LISTS] + i;
        AowlOvList* L = &g_ov.sLists[at];
        char line[128];
        int32_t hot = aowl_ov_hit(x + 1.0f, ry, leftW, (float)AOWL_OV_ROW_H);
        if (at == sel) aowl_ov_rect(x + 1.0f, ry, leftW + AOWL_OV_PAD,
                                    (float)AOWL_OV_ROW_H, AOWL_OV_SELBG);
        else if (hot) aowl_ov_rect(x + 1.0f, ry, leftW + AOWL_OV_PAD,
                                   (float)AOWL_OV_ROW_H, AOWL_OV_ROWALT);
        aowl_ov_fmt(line, sizeof(line), "%s %s", L->active ? ">" : " ",
                    L->name[0] ? L->name : L->id);
        aowl_ov_textn(x + AOWL_OV_PAD, ry + 3.0f, line,
                      L->active ? AOWL_OV_GOOD : AOWL_OV_TEXT, 22);
        aowl_ov_fmt(line, sizeof(line), "%d", L->entries);
        aowl_ov_text(x + AOWL_OV_PAD + leftW - 30.0f, ry + 3.0f, line, AOWL_OV_FAINT);
        if (hot && g_ov.clickDown) {
            g_ov.sel[AOWL_VIEW_LISTS] = at;
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        ry += (float)AOWL_OV_ROW_H;
    }

    /* The right pane: the selected list in full. */
    if (sel < g_ov.sListCount) {
        AowlOvList* L = &g_ov.sLists[sel];
        float dy = y + (float)AOWL_OV_LINE_H;
        char line[256];
        int32_t used, k, shown = 0;
        int32_t maxRows = (int32_t)((bodyH - (dy - y)) / AOWL_OV_LINE_H);

        aowl_ov_fmt(line, sizeof(line), "%s  (%s)%s", L->name, L->id,
                    L->active ? "   ACTIVE" : "");
        aowl_ov_textn(rx, dy, line, L->active ? AOWL_OV_GOOD : AOWL_OV_ACCENT, rcols);
        dy += (float)AOWL_OV_LINE_H;
        if (L->inherits[0]) {
            aowl_ov_fmt(line, sizeof(line), "inherits %s", L->inherits);
            aowl_ov_textn(rx, dy, line, AOWL_OV_DIM, rcols);
            dy += (float)AOWL_OV_LINE_H;
        }
        used = aowl_ov_wrap(rx, dy, L->desc, AOWL_OV_DIM, rcols, 3);
        dy += (float)(used * AOWL_OV_LINE_H) + 6.0f;

        for (k = 0; k < g_ov.sEntryCount && shown < maxRows - 6; k++) {
            AowlOvEntry* E = &g_ov.sEntries[k];
            if (E->list != sel) continue;
            aowl_ov_fmt(line, sizeof(line), "%s %-24.24s %s",
                        E->enabled ? "+" : "-", E->id, E->note);
            aowl_ov_textn(rx, dy, line, E->enabled ? AOWL_OV_TEXT : AOWL_OV_DIM, rcols);
            dy += (float)AOWL_OV_LINE_H;
            shown++;
        }
        if (!L->active) {
            aowl_ov_fmt(line, sizeof(line),
                        "ENTER makes this the active list. Your per-mod "
                        "overrides survive it and keep winning.");
            aowl_ov_wrap(rx, y + bodyH - 34.0f, line, AOWL_OV_ACCENT, rcols, 2);
        }
    }
}

static void aowl_ov_view_issues(float x, float y, float w, float bodyH,
                                int32_t rows) {
    int32_t cols = (int32_t)(w / AOWL_OV_CW);
    int32_t sel = g_ov.sel[AOWL_VIEW_ISSUES];
    float ry = y;
    int32_t i;

    if (g_ov.top[AOWL_VIEW_ISSUES] > sel) g_ov.top[AOWL_VIEW_ISSUES] = sel;
    if (sel - g_ov.top[AOWL_VIEW_ISSUES] >= rows)
        g_ov.top[AOWL_VIEW_ISSUES] = sel - rows + 1;
    if (g_ov.top[AOWL_VIEW_ISSUES] < 0) g_ov.top[AOWL_VIEW_ISSUES] = 0;

    if (g_ov.sLastError[0]) {
        int32_t used = aowl_ov_wrap(x + AOWL_OV_PAD, ry, g_ov.sLastError,
                                    AOWL_OV_ERR, cols - 3, 3);
        ry += (float)(used * AOWL_OV_LINE_H) + 6.0f;
    }
    if (g_ov.sIssueCount == 0) {
        aowl_ov_text(x + AOWL_OV_PAD, ry,
                     g_ov.backendPort > 0
                       ? "nothing excluded and no registry problems."
                       : "no backend, so nothing has been resolved to have a "
                         "problem with.",
                     AOWL_OV_DIM);
        ry += (float)AOWL_OV_LINE_H * 2.0f;
        aowl_ov_wrap(x + AOWL_OV_PAD, ry,
                     "This view lists what the manager refused to load and why: "
                     "a missing or wrong-version requirement, two mods that "
                     "conflict, a requires cycle, a mod whose pipeline range "
                     "excludes this host, and any fault in the registry itself. "
                     "It is filled in before you apply, not after.",
                     AOWL_OV_FAINT, cols - 3, 5);
        return;
    }

    for (i = 0; i < rows && g_ov.top[AOWL_VIEW_ISSUES] + i < g_ov.sIssueCount; i++) {
        int32_t at = g_ov.top[AOWL_VIEW_ISSUES] + i;
        AowlOvIssue* s = &g_ov.sIssues[at];
        char line[256];
        if (at == sel) aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                                    (float)AOWL_OV_ROW_H, AOWL_OV_SELBG);
        aowl_ov_fmt(line, sizeof(line), "%-14.14s %s",
                    s->verdict[0] ? s->verdict : "problem",
                    s->id[0] ? s->id : "");
        aowl_ov_textn(x + AOWL_OV_PAD, ry + 3.0f, line, AOWL_OV_WARN, 40);
        aowl_ov_textn(x + AOWL_OV_PAD + 340.0f, ry + 3.0f, s->text, AOWL_OV_TEXT,
                      cols - 45);
        ry += (float)AOWL_OV_ROW_H;
    }
    if (sel < g_ov.sIssueCount) {
        float dy = y + bodyH - 40.0f;
        aowl_ov_rect(x + 1.0f, dy - 4.0f, w + AOWL_OV_PAD * 2 - 2.0f, 1.0f, AOWL_OV_EDGE);
        aowl_ov_wrap(x + AOWL_OV_PAD, dy, g_ov.sIssues[sel].text, AOWL_OV_TEXT,
                     cols - 3, 2);
    }
}

static void aowl_ov_view_apply(float x, float y, float w, float bodyH,
                               int32_t rows) {
    int32_t cols = (int32_t)(w / AOWL_OV_CW);
    int32_t sel = g_ov.sel[AOWL_VIEW_APPLY];
    float ry = y;
    char line[256];
    int32_t i, used;

    if (g_ov.top[AOWL_VIEW_APPLY] > sel) g_ov.top[AOWL_VIEW_APPLY] = sel;
    if (sel - g_ov.top[AOWL_VIEW_APPLY] >= rows)
        g_ov.top[AOWL_VIEW_APPLY] = sel - rows + 1;
    if (g_ov.top[AOWL_VIEW_APPLY] < 0) g_ov.top[AOWL_VIEW_APPLY] = 0;

    if (!g_ov.sApplyWhat[0] && !g_ov.sLastError[0]) {
        aowl_ov_wrap(x + AOWL_OV_PAD, ry,
                     "Nothing has been changed yet this session. Toggle a mod "
                     "with SPACE, switch lists with ENTER, or press A to push "
                     "the current selection at the host. Whatever the manager "
                     "and the host answer -- per mod, applied or requested or "
                     "deferred or refused -- lands here, in their words.",
                     AOWL_OV_DIM, cols - 3, 5);
        return;
    }

    aowl_ov_fmt(line, sizeof(line), "last: %s", g_ov.sApplyWhat);
    aowl_ov_textn(x + AOWL_OV_PAD, ry, line, AOWL_OV_ACCENT, cols - 2);
    ry += (float)AOWL_OV_LINE_H;

    if (g_ov.sLastError[0]) {
        used = aowl_ov_wrap(x + AOWL_OV_PAD, ry, g_ov.sLastError, AOWL_OV_ERR,
                            cols - 3, 3);
        ry += (float)(used * AOWL_OV_LINE_H);
    }

    /* The three numbers the manager reports about an apply, and the sentence it
     * attaches when any of it was deferred. `restartRequired` is its word, not
     * ours -- the overlay is not allowed to decide that a change took. */
    aowl_ov_fmt(line, sizeof(line),
                "control %s   requested %d   deferred %d   restart required %s",
                g_ov.sApplyControl[0] ? g_ov.sApplyControl
                  : (g_ov.sControl[0] ? g_ov.sControl : "unknown"),
                g_ov.sApplyRequested, g_ov.sApplyDeferred,
                g_ov.sApplyRestart ? "yes" : "no");
    aowl_ov_textn(x + AOWL_OV_PAD, ry, line,
                  g_ov.sApplyRestart ? AOWL_OV_WARN : AOWL_OV_DIM, cols - 2);
    ry += (float)AOWL_OV_LINE_H;

    if (g_ov.sApplyNote[0]) {
        used = aowl_ov_wrap(x + AOWL_OV_PAD, ry, g_ov.sApplyNote, AOWL_OV_WARN,
                            cols - 3, 2);
        ry += (float)(used * AOWL_OV_LINE_H);
    }
    if (g_ov.sInEffect[0]) {
        used = aowl_ov_wrap(x + AOWL_OV_PAD, ry, g_ov.sInEffect, AOWL_OV_TEXT,
                            cols - 3, 2);
        ry += (float)(used * AOWL_OV_LINE_H);
    }
    ry += 6.0f;

    if (g_ov.sResultCount == 0) {
        aowl_ov_text(x + AOWL_OV_PAD, ry, "no per-mod outcomes in that reply",
                     AOWL_OV_DIM);
        return;
    }
    aowl_ov_text(x + AOWL_OV_PAD, ry, "mod", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + 250.0f, ry, "action", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + 330.0f, ry, "outcome", AOWL_OV_FAINT);
    aowl_ov_text(x + AOWL_OV_PAD + 440.0f, ry, "what the host said", AOWL_OV_FAINT);
    ry += (float)AOWL_OV_LINE_H;

    rows = (int32_t)((y + bodyH - ry) / AOWL_OV_ROW_H);
    for (i = 0; i < rows && g_ov.top[AOWL_VIEW_APPLY] + i < g_ov.sResultCount; i++) {
        int32_t at = g_ov.top[AOWL_VIEW_APPLY] + i;
        AowlOvResult* r = &g_ov.sResults[at];
        uint32_t oc = (strcmp(r->outcome, "applied") == 0) ? AOWL_OV_GOOD
                    : (strcmp(r->outcome, "requested") == 0) ? AOWL_OV_ACCENT
                    : (strcmp(r->outcome, "deferred") == 0) ? AOWL_OV_WARN
                    : AOWL_OV_ERR;
        if (at == sel) aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                                    (float)AOWL_OV_ROW_H, AOWL_OV_SELBG);
        else if (i & 1) aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                                     (float)AOWL_OV_ROW_H, AOWL_OV_ROWALT);
        aowl_ov_textn(x + AOWL_OV_PAD, ry + 3.0f, r->id, AOWL_OV_TEXT, 29);
        aowl_ov_textn(x + AOWL_OV_PAD + 250.0f, ry + 3.0f, r->action, AOWL_OV_DIM, 9);
        aowl_ov_textn(x + AOWL_OV_PAD + 330.0f, ry + 3.0f, r->outcome, oc, 13);
        aowl_ov_textn(x + AOWL_OV_PAD + 440.0f, ry + 3.0f, r->message,
                      AOWL_OV_DIM, cols - 57);
        ry += (float)AOWL_OV_ROW_H;
    }
}

/* ------------------------------------------------------------------ *
 * One frame
 * ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ *
 * The geometry cache
 *
 * Laying out the panel is two thirds of what a drawn frame costs -- 43 us of a
 * measured 61, against 18 us for the `Map`, the `Draw` and the fifty-odd
 * `*Get*`/`*Set*` calls that save and restore the game's pipeline state. It is
 * spent writing about seven thousand vertices, one glyph at a time, and on all
 * but a handful of frames it writes exactly what is already there: a mod panel
 * changes when a key is pressed, when the mouse moves, or when a poll lands,
 * which is a few frames a second out of several hundred.
 *
 * So the frame is rebuilt only when something that shows has moved. Everything
 * that can change what is drawn goes into one 32-bit signature; when it matches
 * the last built frame's and no input is waiting, `aowl_ov_build` returns
 * having done nothing, and `aowl_ov_draw` skips both `Map`s -- a DYNAMIC buffer
 * keeps its contents unless it is discarded, so last frame's vertices are still
 * there and still correct.
 *
 * Two things have to be right for this not to be a source of stale frames, and
 * both are cheap to get wrong:
 *
 *  * **Input is checked before the signature.** `aowl_ov_keys` runs inside the
 *    build, so a frame that skips the build would swallow the keypress rather
 *    than defer it. A pending key, click or wheel notch forces a rebuild.
 *  * **Displayed numbers that tick on their own are held still.** The frame
 *    cost on the title bar changes every frame by construction; left in the
 *    signature it would invalidate the cache on every frame and the cache would
 *    cost more than it saved. It, the last request's round trip and the
 *    "stale 11s" age are refreshed twice a second, which is as often as anybody
 *    can read them.
 */

/* ================================================================== *
 * The settings screen
 *
 * A left-hand page nav and a right-hand column of controls, drawn from the
 * schema the worker fetched. Every edit is optimistic on the row and authored
 * by a POST the worker sends; a not-implemented row (all of SPT, and any key a
 * mod flagged) is greyed and inert. The colours are the panel's Tarkov-dark
 * palette, the same one the manager views use.
 * ================================================================== */

/* Write a number back into a row, formatted the way the type wants it: an int
 * with no point, a float minimally. Touches the render thread's own snapshot
 * copy, which the next fetch overwrites with what the file kept. */
/* HOW MANY DECIMALS THIS CONTROL'S NUMBERS ARE WORTH, derived from the control
 * rather than guessed.
 *
 * `%.6g` on a float that arrived as a JSON double printed
 * `0.30000001192092896` for a 0..1 step-0.01 slider, which the value cell then
 * clipped to `0.3000..` -- a number that is both wrong-looking and truncated.
 * The step is the answer: a step of 0.01 can only ever land on two decimals, so
 * printing more digits is printing noise. An integer control gets none; a
 * control with no step at all falls back to its RANGE, on the same reasoning
 * (a 0..1 span needs resolution a 0..1200 span does not).
 *
 * Capped at 4. Past that the digits are below anything a 84-pixel track can
 * address, so they are decoration on a control that cannot produce them. */
static int32_t aowl_ov_num_decimals(const AowlOvSItem* si) {
    float step = si->step;
    int32_t d = 0;
    if (si->kind == AOWL_S_INT) return 0;
    if (!(step > 0.0f) || !aowl_ov_finite(step)) {
        float span = si->hasRange ? (si->hi - si->lo) : 0.0f;
        if (!(span > 0.0f)) return 3;          /* unbounded float: 3 is plenty */
        return span >= 100.0f ? 1 : span >= 10.0f ? 2 : 3;
    }
    /* The smallest d for which the step is representable in d decimals. A
     * step of 0.25 needs two, 0.1 needs one, 5 needs none. */
    while (d < 4) {
        float scaled = step;
        int32_t i;
        for (i = 0; i < d; i++) scaled *= 10.0f;
        {
            float r = scaled - (float)(int32_t)(scaled + 0.5f);
            if (r < 0.0f) r = -r;
            if (r < 0.001f) break;
        }
        d++;
    }
    /* A step finer than the range can address is a step that will never be
     * hit, so the decimals it implies are not worth the width either. */
    if (si->hasRange && si->hi - si->lo >= 1000.0f && d > 2) d = 2;
    return d;
}

/* `v` printed at this control's own precision, and then SHORTENED UNTIL IT
 * FITS `cols` -- decimals first, then a compact exponent. It never returns a
 * string longer than `cols`, so the caller never has to clip one, which is the
 * whole point: a value cell that ends in `..` has told the player a different
 * number than the one the control holds.
 *
 * `cols <= 0` means "no width limit", which is what the raw/write path wants:
 * the value SENT must be the value chosen, never the value that fitted. */
static void aowl_ov_num_str(const AowlOvSItem* si, float v, int32_t cols,
                            char* out, int32_t cap) {
    int32_t d = aowl_ov_num_decimals(si);
    if (si->kind == AOWL_S_INT) {
        aowl_ov_fmt(out, cap, "%d", (int32_t)(v < 0 ? v - 0.5f : v + 0.5f));
    } else {
        aowl_ov_fmt(out, cap, "%.*f", d, (double)v);
    }
    if (cols <= 0) return;
    while ((int32_t)strlen(out) > cols && d > 0) {
        d--;
        aowl_ov_fmt(out, cap, "%.*f", d, (double)v);
    }
    if ((int32_t)strlen(out) > cols) {
        /* Still too wide at zero decimals: the INTEGER part is the problem, so
         * the number gets shorter rather than the string getting cut. `%.*g`
         * with the widest significand that fits, then plain `%g`; either way
         * what is drawn is a number, not a number with its tail removed. */
        int32_t sig = cols - 4 > 1 ? cols - 4 : 1;
        aowl_ov_fmt(out, cap, "%.*g", sig, (double)v);
        while ((int32_t)strlen(out) > cols && sig > 1) {
            sig--;
            aowl_ov_fmt(out, cap, "%.*g", sig, (double)v);
        }
        /* The floor: a number so wide that even one significant digit and an
         * exponent do not fit means the CELL is too small, and saying so with
         * `#` is honest where a truncated digit string is not. */
        if ((int32_t)strlen(out) > cols) {
            int32_t i;
            for (i = 0; i < cols && i < cap - 1; i++) out[i] = '#';
            out[i] = 0;
        }
    }
}

static void aowl_ov_s_fmt_num(AowlOvSItem* si, float v) {
    char t[48];
    /* No width limit here: this is the value that will be WRITTEN. */
    aowl_ov_num_str(si, v, 0, t, (int32_t)sizeof(t));
    aowl_ov_copy(si->raw, (int32_t)sizeof(si->raw), t);
    aowl_ov_copy(si->value, (int32_t)sizeof(si->value), t);
}

/* How long the write slot sits on an edit before sending it. 180 ms is under
 * the ~200 ms a deliberate second gesture takes and well over both the 16 ms
 * frame of a drag and the ~33 ms of a held key`s auto-repeat, so a whole
 * gesture -- however long -- coalesces into ONE write, and two separate
 * gestures never do. */
#define AOWL_OV_WRITE_QUIET_MS 180

/* Send whatever the slot holds, now. Idempotent; safe to call with nothing
 * armed. */
static void aowl_ov_s_flush_now(void) {
    if (!g_ov.pendArm) return;
    g_ov.pendArm = 0;
    g_ov.writeCount++;
    aowl_ov_queue_sset(g_ov.pendPage, g_ov.pendKey, g_ov.pendVal);
}

/* Put an edit in the slot. See the slot`s own comment in `AowlOvState`.
 *
 * The page id is the loaded page, which for a mod is its guid -- exactly the
 * route the edit POSTs to. SPT rows never reach here (they are inert). */
static void aowl_ov_s_commit(AowlOvSItem* si) {
    if (g_ov.pendArm &&
        (strcmp(g_ov.pendKey, si->key) != 0 ||
         strcmp(g_ov.pendPage, g_ov.sItemsPage) != 0))
        aowl_ov_s_flush_now();          /* a different key: do not coalesce */
    aowl_ov_copy(g_ov.pendPage, (int32_t)sizeof(g_ov.pendPage), g_ov.sItemsPage);
    aowl_ov_copy(g_ov.pendKey,  (int32_t)sizeof(g_ov.pendKey),  si->key);
    aowl_ov_copy(g_ov.pendVal,  (int32_t)sizeof(g_ov.pendVal),  si->raw);
    g_ov.pendAt  = GetTickCount();
    g_ov.pendArm = 1;
}

/* Called once per settings frame. Constant cost: one compare when nothing is
 * held, and it never allocates. */
static void aowl_ov_s_flush_tick(void) {
    if (!g_ov.pendArm) return;
    if (GetTickCount() - g_ov.pendAt < (DWORD)AOWL_OV_WRITE_QUIET_MS) return;
    aowl_ov_s_flush_now();
}

/* CLICK-TO-TYPE.
 *
 * The numeric value cell, drawn as a real -- if minimal -- text field, so that
 * a number can be ENTERED rather than only approached. A slider is a good
 * control for "a bit more" and a bad one for "exactly 1.25": at 104 pixels it
 * can address 104 positions, and on a 0..1000 range the value the player wants
 * may simply not be reachable by dragging. The stepper has the same problem in
 * the other direction -- 400 presses.
 *
 * Both variants call this for the same cell, so there is ONE way to type a
 * number on this screen and it looks the same wherever the row came from.
 *
 * Editing state is the existing `editItem`/`editBuf` pair -- the same one the
 * string and keybind editors use -- rather than a second one, because two
 * "which row is being edited" variables is two answers to a question with one
 * true answer, and the focus rules below only work if there is one.
 *
 * Drawn, not asserted: while the box has the row, the cell shows `editBuf` with
 * a caret and an ACCENT frame, and NOT `si->value` -- so what is on screen is
 * what ENTER will parse. */
static void aowl_ov_s_num_box(AowlOvSItem* si, int32_t at, float bx, float by,
                              float bw, int32_t canEdit) {
    int32_t editing = (g_ov.editItem == at);
    int32_t cols;
    if (bw < AOWL_OV_CW) return;
    cols = (int32_t)(bw / AOWL_OV_CW);
    if (editing) {
        char shown[80];
        aowl_ov_rect(bx - 3.0f, by + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6),
                     AOWL_OV_ROWALT);
        aowl_ov_frame_rect(bx - 3.0f, by + 3.0f, bw,
                           (float)(AOWL_OV_ROW_H - 6), 1.0f, AOWL_OV_ACCENT);
        aowl_ov_fmt(shown, (int32_t)sizeof(shown), "%s_", g_ov.editBuf);
        aowl_ov_textn(bx, by + 4.0f, shown, AOWL_OV_TEXT, cols - 1);
        return;
    }
    if (canEdit) {
        /* A hairline under the cell: the affordance. Without it nothing on the
         * row says the number is typeable and the feature is undiscoverable,
         * which is the same as absent. */
        int32_t hot = aowl_ov_hit(bx - 3.0f, by + 3.0f, bw,
                                  (float)(AOWL_OV_ROW_H - 6));
        if (hot)
            aowl_ov_rect(bx - 3.0f, by + 3.0f, bw,
                         (float)(AOWL_OV_ROW_H - 6), AOWL_OV_ROWALT);
        aowl_ov_rect(bx - 3.0f, by + (float)AOWL_OV_ROW_H - 4.0f, bw, 1.0f,
                     hot ? AOWL_OV_ACCENT : AOWL_OV_EDGE);
        if (hot && g_ov.clickDown) {
            g_ov.selItem = at;
            /* Opening the value box TAKES THE KEYBOARD FROM THE SEARCH FIELD.
             * Two focused text fields is the defect this screen already had
             * once, in the other direction. */
            g_ov.searchFocus = 0;
            g_ov.editItem = at;
            g_ov.capturing = 0;
            g_ov.dragItem = -1;
            aowl_ov_copy(g_ov.editBuf, (int32_t)sizeof(g_ov.editBuf),
                         si->value);
            InterlockedExchange(&g_ov.clickDown, 0);
            return;
        }
    }
    /* THE NUMBER IS SHORTENED, NOT CLIPPED.
     *
     * `aowl_ov_textn` ends an over-long string with `..`, which on a numeric
     * cell reads as a DIFFERENT NUMBER -- `0.3000..` is not 0.3 and 12345.. is
     * not 12345. So a numeric row re-renders its value at the width it has
     * (`aowl_ov_num_str` drops decimals, then significant digits, and only
     * fills with `#` when even one digit will not fit), and what reaches
     * `aowl_ov_textn` is already short enough that its ellipsis path cannot
     * fire. Non-numeric rows are unchanged: clipping a string is honest,
     * clipping a number is not. */
    if (si->kind == AOWL_S_INT || si->kind == AOWL_S_FLOAT) {
        char shown[48];
        if (!si->value[0]) {
            aowl_ov_textn(bx, by + 3.0f, "-", AOWL_OV_DIM, cols);
            return;
        }
        aowl_ov_num_str(si, (float)strtod(si->raw, NULL), cols, shown,
                        (int32_t)sizeof(shown));
        aowl_ov_textn(bx, by + 3.0f, shown,
                      canEdit ? AOWL_OV_TEXT : AOWL_OV_DIM, cols);
        return;
    }
    aowl_ov_textn(bx, by + 3.0f, si->value[0] ? si->value : "-",
                  canEdit ? AOWL_OV_TEXT : AOWL_OV_DIM, cols);
}

static void aowl_ov_s_toggle_bool(AowlOvSItem* si) {
    int32_t on = (si->raw[0] == 't' || si->raw[0] == '1');
    aowl_ov_copy(si->raw, (int32_t)sizeof(si->raw), on ? "false" : "true");
    aowl_ov_copy(si->value, (int32_t)sizeof(si->value), si->raw);
    aowl_ov_s_commit(si);
}

static void aowl_ov_s_cycle_enum(AowlOvSItem* si, int32_t dir) {
    int32_t idx = 0, i;
    if (si->optCount <= 0) return;
    for (i = 0; i < si->optCount; i++)
        if (!strcmp(si->opts[i], si->value)) { idx = i; break; }
    idx = (idx + dir + si->optCount) % si->optCount;
    aowl_ov_fmt(si->raw, (int32_t)sizeof(si->raw), "\"%s\"", si->opts[idx]);
    aowl_ov_copy(si->value, (int32_t)sizeof(si->value), si->opts[idx]);
    aowl_ov_s_commit(si);
}

static void aowl_ov_s_adjust(AowlOvSItem* si, int32_t dir) {
    float cur = (float)strtod(si->raw, NULL);
    float step = si->step > 0.0f ? si->step
               : (si->kind == AOWL_S_INT ? 1.0f : 0.01f);
    cur += (float)dir * step;
    if (si->hasRange) {
        if (cur < si->lo) cur = si->lo;
        if (cur > si->hi) cur = si->hi;
    }
    aowl_ov_s_fmt_num(si, cur);
    aowl_ov_s_commit(si);
}

/* A Unity KeyCode-ish name for a virtual key, for a keybind capture. The names
 * are not authoritative -- the keybind rows that exist today are all
 * not-implemented -- but they are the right shape for the day one is wired. */
static void aowl_ov_vk_name(LONG vk, char* out, int32_t cap) {
    if (vk >= 'A' && vk <= 'Z') { out[0] = (char)vk; out[1] = 0; return; }
    if (vk >= '0' && vk <= '9') { out[0] = (char)vk; out[1] = 0; return; }
    if (vk >= VK_F1 && vk <= VK_F12) {
        aowl_ov_fmt(out, cap, "F%d", (int32_t)(vk - VK_F1 + 1)); return;
    }
    switch (vk) {
    case VK_SPACE:   aowl_ov_copy(out, cap, "Space"); return;
    case VK_TAB:     aowl_ov_copy(out, cap, "Tab"); return;
    case VK_SHIFT: case VK_LSHIFT:   aowl_ov_copy(out, cap, "LeftShift"); return;
    case VK_CONTROL: case VK_LCONTROL: aowl_ov_copy(out, cap, "LeftControl"); return;
    case VK_MENU: case VK_LMENU:     aowl_ov_copy(out, cap, "LeftAlt"); return;
    case VK_OEM_3:   aowl_ov_copy(out, cap, "BackQuote"); return;
    case VK_OEM_MINUS: aowl_ov_copy(out, cap, "Minus"); return;
    case VK_OEM_PLUS:  aowl_ov_copy(out, cap, "Equals"); return;
    default: aowl_ov_fmt(out, cap, "Key%d", (int32_t)vk); return;
    }
}

/* A printable character for a virtual key, for the string editor. Uppercase and
 * digits only -- there is no shift state here, and config strings are short
 * tokens rather than prose. 0 means "not a character key". */
static char aowl_ov_vk_char(LONG vk) {
    if (vk >= 'A' && vk <= 'Z') return (char)vk;
    if (vk >= '0' && vk <= '9') return (char)vk;
    if (vk == VK_SPACE)      return ' ';
    if (vk == VK_OEM_MINUS)  return '-';
    if (vk == VK_OEM_PERIOD) return '.';
    if (vk == VK_OEM_2)      return '/';
    /* The NUMERIC KEYPAD. Added for the value box: somebody typing a number
     * reaches for the pad, and without these `4` off the pad produced nothing
     * at all -- a text field that silently ignores half the keys that make the
     * character it wants reads as broken, which is exactly the report that
     * started the focus work. Harmless to the string editor, which accepts
     * digits from the top row already. */
    if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9)
        return (char)('0' + (vk - VK_NUMPAD0));
    if (vk == VK_DECIMAL)    return '.';
    return 0;
}

/* A character the NUMBER box accepts. Deliberately narrower than
 * `aowl_ov_vk_char`: letters must not land in a numeric field, so `E` is
 * rejected and scientific notation is not typeable. `-` is accepted anywhere in
 * the buffer rather than only first -- rejecting it by position here would mean
 * the field refusing a keystroke mid-edit, and `strtod` settles it on ENTER. */
static char aowl_ov_vk_numchar(LONG vk) {
    char c = aowl_ov_vk_char(vk);
    if (c >= '0' && c <= '9') return c;
    if (c == '.' || c == '-') return c;
    if (vk == VK_SUBTRACT) return '-';
    return 0;
}

/* The number of controls the item list can show, given the room the detail
 * strip leaves it. Shared by the render and the key handler so PgUp/PgDn move
 * by exactly what is on screen. */
#define AOWL_OV_SDETAIL_H 62

/* One extra line at the top of the right pane, for the permanent search box.
 * Reserved unconditionally -- the box is always there, not summoned by a key,
 * so the room for it is not conditional either and the row arithmetic does not
 * change under the player mid-interaction. */
/* The search box is a PRIMARY control, not a filter tucked in a corner.
 *
 * With 802 settings on one page it is how anybody actually finds a row, and it
 * was drawn as a 16-pixel strip across half the pane -- the visual weight of a
 * footnote. It is now the full width of the pane and two lines tall: an input
 * line the size of a real text field, and a scope line underneath saying what
 * was searched and how much of it matched.
 *
 * 44 rather than 20 costs the list one row. That is the right trade: a row you
 * cannot see is one scroll away, and a search box you did not notice is 802
 * rows of scrolling. */
#define AOWL_OV_SEARCH_H 44
#define AOWL_OV_SEARCH_BOX 22   /* the input line inside it */

/* A group header in the row list: a filled band, not a hairline. `LINE_H` for
 * the text and 6 above it, so one group visibly ends before the next begins. */
#define AOWL_OV_GHDR_H   (AOWL_OV_LINE_H + 6)

static int32_t aowl_ov_settings_rows(float bodyH) {
    int32_t r = (int32_t)((bodyH - 2.0f * (float)AOWL_OV_LINE_H
                           - (float)AOWL_OV_SEARCH_H
                           - (float)AOWL_OV_SDETAIL_H) / (float)AOWL_OV_ROW_H);
    return r < 1 ? 1 : r;
}

/* How many CONTROL rows a screenful holds once the group bands between them
 * are paid for. PgUp/PgDn moves by this, so the page key lands roughly where
 * the eye expects instead of overshooting by one band per group -- which on a
 * page of three-row groups is most of a screen.
 *
 * An estimate, deliberately, and it is allowed to be: the scroll clamp in the
 * draw is what actually decides what is on screen, and it corrects any
 * overshoot on the next frame. Estimating here and correcting there is one
 * source of truth with a hint, not two computations that can disagree. */
static int32_t aowl_ov_settings_page(float bodyH, int32_t rows) {
    int32_t bands, r;
    if (rows < 1) rows = 1;
    if (g_ov.sCatCount <= 0 || g_ov.sItemCount <= 0) return rows;
    /* Average rows per group, floored at one. */
    bands = g_ov.sItemCount / (g_ov.sCatCount > 0 ? g_ov.sCatCount : 1);
    if (bands < 1) bands = 1;
    r = (int32_t)((float)rows * (float)bands * (float)AOWL_OV_ROW_H
                  / ((float)bands * (float)AOWL_OV_ROW_H
                     + (float)AOWL_OV_GHDR_H));
    (void)bodyH;
    return r < 1 ? 1 : r;
}

/* ------------------------------------------------------------------ *
 * Search
 *
 * WHAT IT SEARCHES, exactly: the row LABEL, the row KEY, and the row`s GROUP
 * PATH. Case-insensitive substring on each; a hit anywhere counts.
 *
 * WHAT IT DOES NOT SEARCH, and every one of these is a deliberate decision
 * rather than an omission:
 *
 *   * the DESCRIPTION. Descriptions are sentences, and matching them turns a
 *     three-letter term into forty hits with no visible reason for any of them
 *     -- the result list would be full of rows whose match is not on screen.
 *     (The served web UI at `mods/uihub` does match descriptions, because a web
 *     page can show the matching sentence under the row. This panel cannot
 *     afford the height, so it does not claim to.)
 *   * the VALUE. Searching "true" would return every bool on the page.
 *   * OTHER PAGES. The box searches the LOADED page only -- one mod, or one SPT
 *     config file. Searching every page means fetching every page, and the
 *     panel says which page it searched on the box itself so this is never a
 *     silent limit.
 *
 * WHERE the hit is is printed on every result row, as the group breadcrumb,
 * because a flat list of 802 labels with no path is ambiguous exactly when it
 * matters -- "Enabled" occurs in nine groups.
 *
 * COST. The filter is a cached array of item indices, recomputed only when the
 * term, the loaded page or the row count changes. A per-frame re-filter over
 * 802 rows is the trap this panel`s geometry cache exists to avoid, and it
 * would defeat that cache as well: a frame that draws the same thing must not
 * do 2,400 string compares to discover that.
 * ------------------------------------------------------------------ */

static void aowl_ov_sig_add(uint32_t* h, int32_t v);   /* defined with the cache */

static int32_t aowl_ov_ci_find(const char* hay, const char* needle) {
    size_t i, j;
    if (!needle[0]) return 1;
    if (!hay || !hay[0]) return 0;
    for (i = 0; hay[i]; i++) {
        for (j = 0; needle[j]; j++) {
            char a = hay[i + j], b = needle[j];
            if (a >= 'A' && a <= 'Z') a = (char)(a + 32);
            if (b >= 'A' && b <= 'Z') b = (char)(b + 32);
            if (a != b) break;
        }
        if (!needle[j]) return 1;
    }
    return 0;
}

static int32_t aowl_ov_smatch(const AowlOvSItem* si, const char* term) {
    return aowl_ov_ci_find(si->label, term) ||
           aowl_ov_ci_find(si->key, term) ||
           aowl_ov_ci_find(si->path, term);
}

/* Recompute `filt` if and only if what it was computed for has moved. Render
 * thread; reads the SNAPSHOT (`sItems`), never the worker`s table. */
static void aowl_ov_search_refresh(void) {
    uint32_t stamp = 2166136261u;
    int32_t i;
    for (i = 0; g_ov.search[i]; i++) aowl_ov_sig_add(&stamp, g_ov.search[i]);
    for (i = 0; g_ov.sItemsPage[i]; i++) aowl_ov_sig_add(&stamp, g_ov.sItemsPage[i]);
    aowl_ov_sig_add(&stamp, g_ov.sItemCount);
    if (!stamp) stamp = 1u;
    if (stamp == g_ov.filtStamp) return;
    g_ov.filtStamp = stamp;
    g_ov.filtCount = 0;
    if (!g_ov.search[0]) return;
    for (i = 0; i < g_ov.sItemCount && g_ov.filtCount < AOWL_OV_MAX_SITEMS; i++)
        if (aowl_ov_smatch(&g_ov.sItems[i], g_ov.search))
            g_ov.filt[g_ov.filtCount++] = i;
}

static int32_t aowl_ov_searching(void) {
    return g_ov.search[0] != 0;
}

/* The position of `item` in `filt`, or the nearest one at or after it. -1 when
 * `filt` is empty. Ascending, so a linear walk is fine at 1,200 and bounded. */
static int32_t aowl_ov_filt_pos(int32_t item) {
    int32_t i;
    if (g_ov.filtCount <= 0) return -1;
    for (i = 0; i < g_ov.filtCount; i++)
        if (g_ov.filt[i] >= item) return i;
    return g_ov.filtCount - 1;
}

/* Is this nav node expanded? OPEN when its flag is set, or when it is an
 * ancestor-or-self of the selected node -- the branch the player is standing
 * in is never collapsed out from under them. Render thread. */
static int32_t aowl_ov_nav_open(int32_t ci, const char* selFull) {
    if (ci < 0 || ci >= g_ov.sCatCount) return 0;
    if (g_ov.navOpen[ci]) return 1;
    if (selFull && selFull[0] &&
        aowl_ov_path_under(selFull, g_ov.sCats[ci].full) &&
        strcmp(selFull, g_ov.sCats[ci].full) != 0) return 1;
    return 0;
}

/* Drop the expansion state when the loaded page changes. Called from the draw,
 * which is the only place that knows the page settled. */
static void aowl_ov_nav_reset_if_page_changed(void) {
    if (strcmp(g_ov.navOpenFor, g_ov.sItemsPage) == 0) return;
    aowl_ov_copy(g_ov.navOpenFor, (int32_t)sizeof(g_ov.navOpenFor),
                 g_ov.sItemsPage);
    memset(g_ov.navOpen, 0, sizeof(g_ov.navOpen));
}

/* ------------------------------------------------------------------ *
 * Group headers
 *
 * Every group on a page prints its NAME. It used to print only a hairline --
 * the player could see that the rows had been divided and could not see into
 * what, which is the "we have a separator but no name" the report named.
 *
 * The name is the part of the row`s path BELOW whatever the nav has selected,
 * joined with " > ": inside "Player" the group under "Player/Health/Regen"
 * heads itself "Health > Regen", and with nothing selected it heads itself with
 * the whole path. When there is nothing below the selection -- the rows sitting
 * directly at the selected node -- the header is the selected node`s own leaf,
 * so the branch that could produce an empty string does not exist.
 * ------------------------------------------------------------------ */
static void aowl_ov_group_title(const AowlOvSItem* si, const char* base,
                                char* out, int32_t cap) {
    const char* rest = si->path;
    int32_t n = 0;
    if (base && base[0] && aowl_ov_path_under(si->path, base)) {
        rest = si->path + strlen(base);
        if (*rest == '/') rest++;
    }
    if (!rest[0]) {
        /* Directly at the selected node: name it after that node rather than
         * printing nothing. */
        aowl_ov_copy(out, cap, base && base[0] ? aowl_ov_path_leaf(base)
                                               : "General");
        return;
    }
    for (; *rest && n < cap - 4; rest++) {
        if (*rest == '/') { out[n++] = ' '; out[n++] = '>'; out[n++] = ' '; }
        else out[n++] = *rest;
    }
    out[n] = 0;
    if (!out[0]) aowl_ov_copy(out, cap, "General");
}

/* The group two adjacent rows belong to, for deciding where a header goes. A
 * header is drawn whenever this changes -- and always before the first row. */
static int32_t aowl_ov_same_group(const AowlOvSItem* a, const AowlOvSItem* b) {
    return strcmp(a->path, b->path) == 0;
}

/* The settings screen's keyboard. Text and keybind capture take a key before
 * navigation does; otherwise the arrows move the cursor and adjust the control,
 * Tab and [ ] change page, and Space/Enter activates. Everything it changes is
 * either the render thread's own cursor or a snapshot row it then POSTs. */
static void aowl_ov_settings_key(LONG vk, int32_t page) {
    int32_t n = g_ov.sItemCount;
    /* The sub-tab the draw is showing. Falls back to the whole page before the
     * first frame has run, when the bounds are still zero. */
    int32_t lo = g_ov.viewLo, hi = g_ov.viewHi;
    AowlOvSItem* si;
    if (hi <= lo || hi > n) { lo = 0; hi = n; }

    /* ================================================================
     * THE FOCUS MODEL, stated once, here, because it is now the rule for
     * TWO text fields rather than one.
     *
     * There are exactly THREE things that can own the keyboard, and never more
     * than one at a time:
     *
     *   1. THE SEARCH BOX          -- `searchFocus`
     *   2. A ROW EDITOR            -- `editItem >= 0`; a string, a keybind
     *                                 capture, or the new number box
     *   3. THE LIST                -- neither of the above; the default
     *
     * The transitions, all of them:
     *
     *   list  -> search    `/`, or a click in the box. Closes any row editor.
     *   list  -> editor    SPACE/ENTER on an editable row, or a click on its
     *                      value cell. Clears `searchFocus`.
     *   search-> list      ESC (clears the term), or ENTER/TAB/DOWN (keeps it).
     *   search-> editor    NOT DIRECTLY. Leave the box first; there is no
     *                      gesture that opens an editor while the box is
     *                      focused, so the two can never both be up.
     *   editor-> list      ESC (abandons), or ENTER (commits). A click in the
     *                      search box also abandons it -- see the draw.
     *
     * ESC NEVER CLOSES THE PANEL from either field; it returns the keyboard to
     * the list, and only an ESC that the LIST receives closes the panel. That
     * is confirmed working and is deliberately unchanged here.
     *
     * WHY THE INVARIANT IS ENFORCED RATHER THAN MAINTAINED: `searchFocus` is
     * tested first below, so if both were ever set the field drawing a caret
     * would not be the field receiving keys -- silent, and indistinguishable
     * from a dead keyboard. Rather than trust every transition above to have
     * cleared the other, the impossible state is CORRECTED here, once, at the
     * only place both are read. If it is ever entered, the row editor wins:
     * it is the more recent and the more destructive to lose.
     *
     * AND WHY EVERY SHORTCUT IS A FUNCTION KEY: F2, F8, F9, F10, F11, F12 are
     * handled in `aowl_ov_keys` BEFORE this function is reached, so no field on
     * this screen can eat one. A shortcut a text field can swallow is not a
     * shortcut -- that is the whole lesson of `-`/`=`, and adding a second text
     * field is exactly when it would have been re-learned the hard way.
     * ================================================================ */
    if (g_ov.searchFocus && g_ov.editItem >= 0) g_ov.searchFocus = 0;

    /* --- the search box owns the keyboard while it has focus -------------
     *
     * Checked FIRST, before the edit-in-progress branch and before navigation,
     * because a text field that lets some of its characters through to a
     * shortcut is a text field the player cannot type in. ESC gives the
     * keyboard back and clears the term -- one key to undo the whole gesture;
     * ENTER and DOWN keep the term and move into the results, which is what
     * makes it keyboard-drivable end to end. */
    if (g_ov.searchFocus) {
        int32_t L;
        char ch;
        if (vk == VK_ESCAPE) {
            g_ov.search[0] = 0; g_ov.searchFocus = 0; return;
        }
        if (vk == VK_RETURN || vk == VK_DOWN || vk == VK_TAB) {
            g_ov.searchFocus = 0;
            return;
        }
        if (vk == VK_BACK) {
            L = (int32_t)strlen(g_ov.search);
            if (L > 0) g_ov.search[L - 1] = 0;
            return;
        }
        ch = aowl_ov_vk_char(vk);
        if (ch) {
            /* LOWER CASE. `aowl_ov_vk_char` returns the virtual key, which for
             * a letter is its capital -- so typing `regen` put `REGEN` in the
             * box. The match is case-insensitive either way, so this changes
             * nothing about what is found and everything about whether the
             * field looks like it is working: a text box that shouts back what
             * you typed reads as broken. The string editor keeps the old
             * behaviour, because there the case is the VALUE. */
            if (ch >= 0x41 && ch <= 0x5A) ch = (char)(ch + 32);
            L = (int32_t)strlen(g_ov.search);
            if (L < (int32_t)sizeof(g_ov.search) - 1) {
                g_ov.search[L] = ch; g_ov.search[L + 1] = 0;
            }
        }
        return;
    }
    /* `/` puts the keyboard in the box. The box itself is ALWAYS on screen --
     * this is a focus key, not a summon key. */
    if (vk == VK_OEM_2 && g_ov.editItem < 0) { g_ov.searchFocus = 1; return; }

    /* --- moving inside a result list ------------------------------------
     *
     * With a term up, the rows on screen are `filt`, not a contiguous range, so
     * up and down step through `filt` and ENTER leaves the results at the row
     * it landed on: the term is cleared and the nav is pointed at that row`s
     * own group, which is the "jump to it" half of the gesture. `selItem` stays
     * an ITEM index throughout, exactly as it does for sub-tabs, so every edit
     * path below is untouched by search as well. */
    if (aowl_ov_searching() && g_ov.editItem < 0) {
        int32_t at = aowl_ov_filt_pos(g_ov.selItem);
        if (g_ov.filtCount > 0 &&
            (vk == VK_UP || vk == VK_DOWN || vk == VK_PRIOR ||
             vk == VK_NEXT || vk == VK_HOME || vk == VK_END ||
             vk == VK_RETURN)) {
            if (at < 0) at = 0;
            if (vk == VK_UP)    at--;
            if (vk == VK_DOWN)  at++;
            if (vk == VK_PRIOR) at -= page;
            if (vk == VK_NEXT)  at += page;
            if (vk == VK_HOME)  at = 0;
            if (vk == VK_END)   at = g_ov.filtCount - 1;
            if (at < 0) at = 0;
            if (at >= g_ov.filtCount) at = g_ov.filtCount - 1;
            g_ov.selItem = g_ov.filt[at];
            if (vk == VK_RETURN) {
                /* Land on the row IN ITS GROUP: the deepest nav node that
                 * contains it, so the breadcrumb after the jump says where the
                 * player now is rather than leaving them at "the whole page". */
                int32_t c, best = -1;
                for (c = 0; c < g_ov.sCatCount; c++)
                    if (g_ov.selItem >= g_ov.sCats[c].lo &&
                        g_ov.selItem < g_ov.sCats[c].hi &&
                        (best < 0 || g_ov.sCats[c].depth > g_ov.sCats[best].depth))
                        best = c;
                g_ov.selCat = best;
                g_ov.search[0] = 0;
                g_ov.topItem = g_ov.selItem;
            }
            return;
        }
        if (vk == VK_ESCAPE) { g_ov.search[0] = 0; return; }
    }
    si = (g_ov.selItem >= 0 && g_ov.selItem < n)
                        ? &g_ov.sItems[g_ov.selItem] : NULL;
    int32_t canEdit = si && si->implemented && g_ov.curPageIsMod &&
                      si->kind != AOWL_S_NESTED;

    /* --- an edit in progress eats the key ------------------------------- */
    if (g_ov.editItem >= 0 && g_ov.editItem < n) {
        AowlOvSItem* e = &g_ov.sItems[g_ov.editItem];
        if (g_ov.capturing && e->kind == AOWL_S_KEYBIND) {
            char nm[32];
            if (vk == VK_ESCAPE) { g_ov.capturing = 0; g_ov.editItem = -1; return; }
            aowl_ov_vk_name(vk, nm, (int32_t)sizeof(nm));
            aowl_ov_fmt(e->raw, (int32_t)sizeof(e->raw), "\"%s\"", nm);
            aowl_ov_copy(e->value, (int32_t)sizeof(e->value), nm);
            aowl_ov_s_commit(e);
            g_ov.capturing = 0; g_ov.editItem = -1;
            return;
        }
        if (e->kind == AOWL_S_STRING) {
            char ch;
            int32_t L;
            if (vk == VK_RETURN) {
                aowl_ov_fmt(e->raw, (int32_t)sizeof(e->raw), "\"%s\"", g_ov.editBuf);
                aowl_ov_copy(e->value, (int32_t)sizeof(e->value), g_ov.editBuf);
                aowl_ov_s_commit(e);
                g_ov.editItem = -1;
                return;
            }
            if (vk == VK_ESCAPE) { g_ov.editItem = -1; return; }
            if (vk == VK_BACK) {
                L = (int32_t)strlen(g_ov.editBuf);
                if (L > 0) g_ov.editBuf[L - 1] = 0;
                return;
            }
            ch = aowl_ov_vk_char(vk);
            if (ch) {
                L = (int32_t)strlen(g_ov.editBuf);
                if (L < (int32_t)sizeof(g_ov.editBuf) - 1) {
                    g_ov.editBuf[L] = ch; g_ov.editBuf[L + 1] = 0;
                }
            }
            return;
        }
        /* THE NUMBER BOX. Same shape as the string editor above -- ENTER
         * commits, ESC abandons, BACKSPACE deletes -- and the only differences
         * are that it takes digits rather than letters and that what it commits
         * is CLAMPED and RE-FORMATTED.
         *
         * The clamp is the point. A typed value is the one place the player can
         * name a number outside the declared range, and the row must not end up
         * showing a value the file will not hold. So the committed text is
         * produced by `aowl_ov_s_fmt_num` from the CLAMPED float rather than
         * from the buffer, which also means `3.` and `007` come back as `3` and
         * `7` -- the row shows what was stored, never what was typed at it.
         *
         * An unparseable buffer (empty, or just `-`) is a CANCEL, not a write
         * of zero. Storing 0 because somebody cleared the field and pressed
         * ENTER is a silent destructive edit. */
        if (e->kind == AOWL_S_INT || e->kind == AOWL_S_FLOAT) {
            char ch;
            int32_t L;
            if (vk == VK_RETURN) {
                const char* b = g_ov.editBuf;
                char* fin = NULL;
                double d = strtod(b, &fin);
                g_ov.editItem = -1;
                if (!fin || fin == b || !aowl_ov_finite((float)d)) return;
                if (e->hasRange) {
                    if (d < (double)e->lo) d = (double)e->lo;
                    if (d > (double)e->hi) d = (double)e->hi;
                }
                aowl_ov_s_fmt_num(e, (float)d);
                aowl_ov_s_commit(e);
                return;
            }
            if (vk == VK_ESCAPE) { g_ov.editItem = -1; return; }
            if (vk == VK_BACK) {
                L = (int32_t)strlen(g_ov.editBuf);
                if (L > 0) g_ov.editBuf[L - 1] = 0;
                return;
            }
            ch = aowl_ov_vk_numchar(vk);
            if (ch) {
                L = (int32_t)strlen(g_ov.editBuf);
                if (L < (int32_t)sizeof(g_ov.editBuf) - 1) {
                    g_ov.editBuf[L] = ch; g_ov.editBuf[L + 1] = 0;
                }
            }
            /* Everything else is SWALLOWED. A number field that lets the arrow
             * keys through would move the row cursor out from under its own
             * edit -- and the edit would then commit onto a different setting.
             * The only keys that escape a focused field on this screen are the
             * function keys, which `aowl_ov_keys` takes before this runs. */
            return;
        }
    }

    /* --- THE NAV HAS THE KEYBOARD ---------------------------------------
     *
     * Everything below this point drives the CONTROL list, so the whole block
     * has to be claimed here and returned from rather than fallen through:
     * a nav that moves the page cursor AND the control cursor on one DOWN has
     * not got focus, it has got both. UP/DOWN step the tree in the same
     * flattened order `,`/`.` use, PgUp/PgDn and `[`/`]` walk the pages,
     * LEFT/RIGHT close and open a branch, HOME goes back out to the page.
     *
     * Anything it does not name -- F-keys, the search box, ESC -- was taken by
     * `aowl_ov_keys` before this function ran, so no shortcut is swallowed by
     * having focus over here. */
    if (g_ov.navFocus) {
        if (vk == VK_DOWN || vk == 'S' || vk == VK_NEXT) {
            if (g_ov.sCatCount > 1 && g_ov.selCat < g_ov.sCatCount - 1) {
                g_ov.selCat++;
                g_ov.navOpen[g_ov.selCat] = 1;
                g_ov.selItem = g_ov.sCats[g_ov.selCat].lo;
                g_ov.topItem = g_ov.selItem;
            } else if (g_ov.selPage < g_ov.sPageCount - 1) {
                g_ov.selPage++;
                g_ov.pageOpen[g_ov.selPage] = 1;
            }
            return;
        }
        if (vk == VK_UP || vk == 'W' || vk == VK_PRIOR) {
            if (g_ov.selCat >= 0) {
                g_ov.selCat--;
                if (g_ov.selCat >= 0) {
                    g_ov.selItem = g_ov.sCats[g_ov.selCat].lo;
                    g_ov.topItem = g_ov.selItem;
                }
            } else if (g_ov.selPage > 0) {
                g_ov.selPage--;
                g_ov.pageOpen[g_ov.selPage] = 1;
            }
            return;
        }
        if (vk == VK_RIGHT && g_ov.selCat >= 0 && g_ov.selCat < g_ov.sCatCount) {
            g_ov.navOpen[g_ov.selCat] = 1; return;
        }
        if (vk == VK_LEFT && g_ov.selCat >= 0 && g_ov.selCat < g_ov.sCatCount) {
            g_ov.navOpen[g_ov.selCat] = 0; return;
        }
        if (vk == VK_HOME) { g_ov.selCat = -1; g_ov.selItem = 0;
                             g_ov.topItem = 0; return; }
        /* RETURN steps INTO the page: the natural "I have found it, now let me
         * change something" move, and the only way off the nav other than TAB. */
        if (vk == VK_RETURN || vk == VK_SPACE) { g_ov.navFocus = 0; return; }
    }
    /* --- navigation ------------------------------------------------------ */
    if (vk == VK_UP   || vk == 'W') { if (g_ov.selItem > lo) g_ov.selItem--; return; }
    if (vk == VK_DOWN || vk == 'S') { if (g_ov.selItem < hi - 1) g_ov.selItem++; return; }
    if ((vk == VK_PRIOR || vk == VK_NEXT) && (GetKeyState(VK_SHIFT) & 0x8000)) {
        g_ov.topPage += (vk == VK_NEXT ? +1 : -1) * (page > 1 ? page - 1 : 1);
        if (g_ov.topPage < 0) g_ov.topPage = 0;
        g_ov.navFree = 1;    /* clamped against the real list by the draw */
        return;
    }
    if (vk == VK_PRIOR) { g_ov.selItem -= page; if (g_ov.selItem < lo) g_ov.selItem = lo; return; }
    if (vk == VK_NEXT)  { g_ov.selItem += page;
                          if (g_ov.selItem > hi - 1) g_ov.selItem = hi - 1;
                          if (g_ov.selItem < lo) g_ov.selItem = lo; return; }
    if (vk == VK_HOME) { g_ov.selItem = lo; return; }
    if (vk == VK_END)  { g_ov.selItem = hi > lo ? hi - 1 : lo; return; }
    /* `,` and `.` walk the nav TREE of the page already selected, in the same
     * flattened order the nav draws -- so at arbitrary depth, and including
     * back out to "the whole page" at -1. A 802-row page is reachable from the
     * keyboard without the mouse. A page with one group draws no tree and these
     * do nothing. */
    if (vk == VK_OEM_COMMA || vk == VK_OEM_PERIOD) {
        if (g_ov.sCatCount > 1) {
            g_ov.selCat += (vk == VK_OEM_PERIOD) ? 1 : -1;
            if (g_ov.selCat < -1) g_ov.selCat = g_ov.sCatCount - 1;
            if (g_ov.selCat >= g_ov.sCatCount) g_ov.selCat = -1;
            g_ov.selItem = (g_ov.selCat >= 0) ? g_ov.sCats[g_ov.selCat].lo : 0;
            g_ov.topItem = g_ov.selItem;
        }
        return;
    }
    /* `+`/`-` on the NUMBER PAD open and close the selected branch, and so do
     * the arrow keys when the cursor is on a node: RIGHT opens, LEFT closes and
     * then steps out to the parent. That is what every tree on this platform
     * does, and it is the keyboard half of the disclosure markers -- a tree you
     * can only expand with the mouse is not usable by somebody driving this
     * from the keyboard, which is most of the point of the panel. */
    if ((vk == VK_ADD || vk == VK_SUBTRACT) && g_ov.selCat >= 0 &&
        g_ov.selCat < g_ov.sCatCount) {
        g_ov.navOpen[g_ov.selCat] = (vk == VK_ADD);
        return;
    }
    /* --- TAB: WHICH LIST THE KEYBOARD IS DRIVING ------------------------
     *
     * TAB used to be a second `]` -- next page -- which is a key spent on
     * something `]` already did. It now moves focus between the nav column and
     * the control list, so a person on the keyboard can drive either half of
     * the screen with the arrows, which is the half of the input model that
     * was missing. `[`/`]` still walk the pages from either side, so nothing
     * that worked before has been taken away.
     *
     * TAB IN THE MOD MANAGER IS NOT TOUCHED: that is `aowl_ov_keys`, which
     * only reaches its own `VK_TAB` case when `g_ov.settings` is 0, and it
     * still cycles the view. Two screens, two meanings, one key -- which is
     * what TAB means on every other application on this platform too. */
    if (vk == VK_TAB) { g_ov.navFocus = !g_ov.navFocus; return; }
    if (vk == VK_OEM_4) { if (g_ov.selPage > 0) g_ov.selPage--; return; }          /* [ */
    if (vk == VK_OEM_6) { if (g_ov.selPage < g_ov.sPageCount - 1) g_ov.selPage++; return; } /* ] */

    /* --- THE NAV, FROM THE KEYBOARD --------------------------------------
     *
     * `[` and `]` walk the PAGES and `+`/`-` open and close a branch, but
     * before this there was no key that moved DOWN INTO one: the group cursor
     * could only be placed with the mouse, so on a page with a deep tree the
     * keyboard could reach the page and nothing inside it.
     *
     * `,` and `.` step the group cursor through `sCats` -- which is the whole
     * tree in path order -- so every node is reachable in a bounded number of
     * presses at any depth. Ancestors open on the way because
     * `aowl_ov_nav_open` treats "the selection is inside me" as open, the same
     * rule the mouse path uses; there is no second notion of expansion to
     * disagree with the first. `,` from the first group goes to -1, the page
     * itself, which is where the cursor started.
     *
     * SHIFT+PgUp/PgDn scrolls the nav VIEW without moving the cursor, which is
     * the "look at the rest of the list" gesture the wheel gives the mouse. */
    if (vk == VK_OEM_COMMA) {
        if (g_ov.selCat >= 0) {
            g_ov.selCat--;
            if (g_ov.selCat >= 0) {
                g_ov.selItem = g_ov.sCats[g_ov.selCat].lo;
                g_ov.topItem = g_ov.selItem;
            }
        }
        return;
    }
    if (vk == VK_OEM_PERIOD) {
        if (g_ov.selCat < g_ov.sCatCount - 1) {
            g_ov.selCat++;
            g_ov.navOpen[g_ov.selCat] = 1;
            g_ov.selItem = g_ov.sCats[g_ov.selCat].lo;
            g_ov.topItem = g_ov.selItem;
        }
        return;
    }

    if (!canEdit) return;
    /* --- change the selected control ------------------------------------ */
    if (vk == VK_LEFT) {
        if (si->kind == AOWL_S_BOOL) aowl_ov_s_toggle_bool(si);
        else if (si->kind == AOWL_S_ENUM) aowl_ov_s_cycle_enum(si, -1);
        else if (si->kind == AOWL_S_INT || si->kind == AOWL_S_FLOAT)
            aowl_ov_s_adjust(si, -1);
        return;
    }
    if (vk == VK_RIGHT) {
        if (si->kind == AOWL_S_BOOL) aowl_ov_s_toggle_bool(si);
        else if (si->kind == AOWL_S_ENUM) aowl_ov_s_cycle_enum(si, +1);
        else if (si->kind == AOWL_S_INT || si->kind == AOWL_S_FLOAT)
            aowl_ov_s_adjust(si, +1);
        return;
    }
    if (vk == VK_SPACE || vk == VK_RETURN) {
        if (si->kind == AOWL_S_BOOL) aowl_ov_s_toggle_bool(si);
        else if (si->kind == AOWL_S_ENUM) aowl_ov_s_cycle_enum(si, +1);
        else if (si->kind == AOWL_S_KEYBIND) {
            g_ov.editItem = g_ov.selItem; g_ov.capturing = 1;
        } else if (si->kind == AOWL_S_STRING) {
            g_ov.editItem = g_ov.selItem; g_ov.capturing = 0;
            aowl_ov_copy(g_ov.editBuf, (int32_t)sizeof(g_ov.editBuf), si->value);
        } else if (si->kind == AOWL_S_INT || si->kind == AOWL_S_FLOAT) {
            /* The keyboard half of click-to-type, so the value box is reachable
             * without the mouse like everything else on this screen. */
            g_ov.editItem = g_ov.selItem; g_ov.capturing = 0;
            g_ov.dragItem = -1;
            aowl_ov_copy(g_ov.editBuf, (int32_t)sizeof(g_ov.editBuf), si->value);
        }
        return;
    }
}

static void aowl_ov_view_settings(float x, float y, float w, float bodyH) {
    /* Wider than the flat two-level list needed. A tree spends its left edge
     * on depth, and a nav that indents four levels into a 208-wide column has
     * ~14 characters left for the name -- which is how "Regeneration" became
     * "Regenera.." and every deep node started looking like every other. */
    /* 256 by default, and settable from the panel's own page -- a person with
     * deeply nested mod settings wants more, a person on a small window wants
     * less, and neither of them should have to rebuild the host to get it. */
    const float leftW = (float)(g_ov.navW >= 140 && g_ov.navW <= 640
                                ? g_ov.navW : 256);
    float rx = x + (float)AOWL_OV_PAD + leftW + 12.0f;
    float rrEdge = x + w + (float)AOWL_OV_PAD;       /* right inner edge */
    float rw = rrEdge - rx;
    int32_t rcols = (int32_t)(rw / (float)AOWL_OV_CW);
    float ctlW = 156.0f;
    float ctlX = rrEdge - ctlW;
    float scaleK = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float mxp = (float)g_ov.mx / scaleK;
    int32_t pc = g_ov.sPageCount;
    int32_t navRows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H) / (float)AOWL_OV_ROW_H);
    int32_t iRows = aowl_ov_settings_rows(bodyH);
    int32_t i;
    AowlOvSPage* P;
    int32_t loaded;
    float ny, cy;
    /* The flattened two-level nav for this frame. Automatic, not state: it is
     * derived from `sPages`/`sCats`/`selPage` every frame and nothing outside
     * this function ever reads it. ~576 bytes of stack. */
    int32_t navPage[AOWL_OV_MAX_NAV];
    int32_t navCat[AOWL_OV_MAX_NAV];
    int32_t navCount = 0, navSel = 0;
    int32_t lo = 0, hi = 0;
    /* The selected node`s full path, at function scope: the flattening uses it
     * to decide what to expand and the row drawing uses it to decide whether a
     * node`s marker reads `-` (open) or `+` (closed). Two computations of "is
     * this node on the path to the selection" would be two chances to disagree,
     * and a tree whose markers disagree with its own expansion is worse than
     * one with no markers. */
    char navSelFull[160];
    if (navRows < 1) navRows = 1;
    /* THE WRITE SLOT, once per frame, before anything else can arm it again.
     * One integer compare when nothing is held. */
    aowl_ov_s_flush_tick();
    /* A DRAG ENDS WHEN THE BUTTON IS UP, wherever the row is.
     *
     * This used to live inside the row-draw branch, which meant it only ran
     * while the dragged row was still on screen AND still editable. Release the
     * button after the list has scrolled -- or over the nav, or outside the
     * window -- and `dragItem` stayed set: the next click anywhere near a
     * slider resumed a drag the player thought they had finished. Ending it
     * here, from the state the wndproc publishes, has no such precondition. */
    if (!g_ov.mouseHeld) g_ov.dragItem = -1;
    /* The expansion state belongs to the page that is loaded; a stale index
     * would expand whatever now sits at it. */
    aowl_ov_nav_reset_if_page_changed();
    navSelFull[0] = 0;
    if (g_ov.selCat >= 0 && g_ov.selCat < g_ov.sCatCount)
        aowl_ov_copy(navSelFull, (int32_t)sizeof(navSelFull),
                     g_ov.sCats[g_ov.selCat].full);

    /* --- keep the page cursor sane and request its controls once ---------- */
    if (g_ov.selPage >= pc) g_ov.selPage = pc > 0 ? pc - 1 : 0;
    if (g_ov.selPage < 0) g_ov.selPage = 0;
    if (pc > 0) {
        P = &g_ov.sPages[g_ov.selPage];
        if (strcmp(g_ov.curPage, P->id) != 0) {
            /* Leaving a page must not abandon an edit made on it a moment ago.
             * Flushed BEFORE `sItemsPage` moves, so the write still carries the
             * page it was made on. */
            aowl_ov_s_flush_now();
            aowl_ov_copy(g_ov.curPage, (int32_t)sizeof(g_ov.curPage), P->id);
            g_ov.curPageIsMod = P->isMod;
            /* A page you have just moved to is OPEN. The alternative -- landing
             * on a page whose tree is shut -- reads as a page with nothing in
             * it, which is the worst possible first impression of a screen
             * whose whole job is to show you 802 settings. */
            g_ov.pageOpen[g_ov.selPage] = 1;
            g_ov.selCat = -1;
            g_ov.selItem = 0; g_ov.topItem = 0;
            g_ov.editItem = -1; g_ov.capturing = 0; g_ov.dragItem = -1;
            aowl_ov_queue_spage(P->id, P->isMod);
        }
    }

    /* --- the left nav ----------------------------------------------------- */
    /* The nav is flattened here, once per frame, into "a page row" or "a group
     * row of the selected page". One loop, any depth: the alternative was a
     * second loop with its own scroll, its own hit testing and its own
     * off-by-one, for a list that is at most AOWL_OV_MAX_NAV rows.
     *
     * A group row is shown when it is TOP LEVEL, or when its parent is on the
     * path from the root to the selection -- the ordinary expand-along-the-
     * selection tree. That is what keeps the nav to a screenful on a page with
     * a deep tree while leaving every node reachable: to get to any node you
     * walk down through its ancestors, each of which is visible by the time you
     * are at its parent. The nodes are already in path order (`build_cats`
     * emits them as it walks the sorted rows), so the flattening is one pass
     * and children sit directly under their parent with no sorting here. */
    {
        int32_t k;
        navCount = 0;
        for (k = 0; k < pc && navCount < AOWL_OV_MAX_NAV; k++) {
            navPage[navCount] = k; navCat[navCount] = -1; navCount++;
            if (k == g_ov.selPage && g_ov.pageOpen[k] && g_ov.sCatCount > 1 &&
                strcmp(g_ov.sItemsPage, g_ov.sPages[k].id) == 0 &&
                !g_ov.sItemsErr) {
                int32_t c;
                /* A node is on screen when EVERY ancestor of it is open, not
                 * merely its parent. `vis[c]` carries that down the list, which
                 * works in one pass because `build_cats` emits nodes in path
                 * order, so a parent is always decided before its children.
                 *
                 * Testing only the parent looks right and is not: closing
                 * `Player` while `Player/Health` was open left
                 * `Player/Health/Regeneration` on screen -- a grandchild of a
                 * collapsed branch, floating under nothing. Measured, not
                 * reasoned: the nav read back `Regeneration` at x=114 with
                 * `Health` gone from the same column. */
                int32_t vis[AOWL_OV_MAX_SCATS];
                for (c = 0; c < g_ov.sCatCount && navCount < AOWL_OV_MAX_NAV; c++) {
                    AowlOvSCat* C = &g_ov.sCats[c];
                    int32_t show;
                    if (C->depth == 1) show = 1;
                    else if (C->parent >= 0 && C->parent < g_ov.sCatCount)
                        show = vis[C->parent] &&
                               aowl_ov_nav_open(C->parent, navSelFull);
                    else show = 0;
                    vis[c] = show;
                    if (!show) continue;
                    navPage[navCount] = k; navCat[navCount] = c; navCount++;
                }
            }
        }
    }
    /* WHERE THE CURSOR IS IN THE FLATTENED LIST -- computed HERE, after the
     * flattening, because that is when the list exists.
     *
     * It used to run BEFORE it, against `navCount == 0`: both loops ran zero
     * times, `navSel` fell through to its `0` default every single frame, and
     * row 0 -- the PAGE -- was drawn selected no matter what was actually
     * chosen. That is the whole of "it only shows Singleplayer as selected
     * even if you click a sub-page": the tree knew the answer and the answer
     * was being overwritten by a fallback before anything could read it.
     *
     * Found by counting highlighted rows on the back buffer, not by reading
     * this code -- the ordering is invisible until you ask the screen. */
    {
        int32_t k;
        navSel = -1;
        for (k = 0; k < navCount; k++)
            if (navPage[k] == g_ov.selPage && navCat[k] == g_ov.selCat) {
                navSel = k; break;
            }
        /* No exact row: the group is not drawn yet because the page is still
         * loading, or it sits inside a branch the player has collapsed. Fall
         * back to the PAGE's own row rather than to zero -- zero would scroll
         * the nav to the top for as long as a fetch takes, which reads as the
         * nav resetting itself. */
        if (navSel < 0)
            for (k = 0; k < navCount; k++)
                if (navPage[k] == g_ov.selPage) { navSel = k; break; }
        if (navSel < 0) navSel = 0;
    }
    /* --- THE WHEEL, ROUTED ------------------------------------------------
     *
     * Over the nav column it scrolls the nav; over the control list it scrolls
     * the CONTROL LIST. Three rows a notch, the Windows convention, and the
     * same number both sides so the two lists feel like one surface.
     *
     * The boundary is the divider, which is drawn at
     * `x + PAD + leftW + 5` a few lines below: one pixel further right so that
     * the divider column itself belongs to the nav rather than to neither.
     * `leftW` is read from `navW` at the top of this function, so a person who
     * has widened the nav on the panel`s own page moves this line with it --
     * a hard-coded boundary would be right only at the default width.
     *
     * IT SCROLLS THE VIEW, NOT THE SELECTION. It used to move `selItem` and
     * leave the follow-clamp to decide whether anything moved on screen, so
     * with the cursor mid-viewport the first notches did nothing visible while
     * the nav -- which has always free-scrolled -- responded instantly. That
     * asymmetry is what was reported, not the routing: the routing is asserted
     * both ways in tests/overlayhost/uxtest.c and passes unchanged. */
    {
        int32_t notches = g_ov.navWheel;
        g_ov.navWheel = 0;
        if (notches) {
            float navRight = x + (float)AOWL_OV_PAD + leftW + 6.0f;
            if (mxp < navRight) {
                g_ov.topPage -= 3 * notches;
                g_ov.navFree = 1;
            } else {
                g_ov.topItem -= 3 * notches;
                g_ov.itemFree = 1;   /* clamped against the real list by the draw */
            }
        }
    }
    /* Following the cursor is what the nav does UNLESS the player has just
     * scrolled it themselves. Both clamps below still run either way -- a free
     * scroll may leave the list past its own end, and a list scrolled past its
     * end shows blank rows and reads as broken. */
    if (navSel != g_ov.navSelSeen) { g_ov.navFree = 0; g_ov.navSelSeen = navSel; }
    if (!g_ov.navFree) {
        if (g_ov.topPage > navSel) g_ov.topPage = navSel;
        if (navSel - g_ov.topPage >= navRows)
            g_ov.topPage = navSel - navRows + 1;
    }
    if (g_ov.topPage > navCount - navRows) g_ov.topPage = navCount - navRows;
    if (g_ov.topPage < 0) g_ov.topPage = 0;

    /* THE COLUMN HEADER CARRIES THE HIERARCHY NOW, not a per-row border.
     *
     * Every top-level row here is a mod (or an SPT config surface, which is
     * already dimmed and already carries its own NI tag), and everything
     * indented under one is a group inside it. That was previously said with a
     * hairline above each root row -- a rule the eye reads as a SEPARATOR
     * between unrelated things, which is the opposite of what it meant, and
     * which the reporter disliked on sight.
     *
     * It is DROPPED rather than replaced with a quieter mark. The indentation
     * already answers the question: a root sits at x + PAD behind a
     * two-column marker, and a group at depth d sits three columns per level
     * further in behind a guide rule and an elbow drawn under its parent -- so
     * the only rows flush with the left edge ARE the roots. A second signal
     * for something already unambiguous is noise. The header names what they
     * are.
     *
     * AOWL_OV_FAINT is a theme token, not a colour: themes are data files and
     * this line has to move when one is loaded. */
    aowl_ov_text(x + (float)AOWL_OV_PAD, y, "mods", AOWL_OV_FAINT);
    aowl_ov_rect(x + (float)AOWL_OV_PAD + leftW + 5.0f, y, 1.0f, bodyH, AOWL_OV_EDGE);
    ny = y + (float)AOWL_OV_LINE_H;
    if (pc == 0) {
        aowl_ov_wrap(x + (float)AOWL_OV_PAD, ny,
                     g_ov.backendPort <= 0
                       ? "no mods -- the settings screen needs a backend to "
                         "read the schema from"
                       : (g_ov.sIdxWhy[0]
                            ? g_ov.sIdxWhy
                            : "no mods yet -- waiting for the settings index"),
                     AOWL_OV_DIM, 24, 6);
    }
    for (i = 0; i < navRows && g_ov.topPage + i < navCount; i++) {
        int32_t at = g_ov.topPage + i;
        int32_t pi = navPage[at], ci = navCat[at];
        AowlOvSPage* Q = &g_ov.sPages[pi];
        int32_t hot = aowl_ov_hit(x + 1.0f, ny, leftW + (float)AOWL_OV_PAD,
                                  (float)AOWL_OV_ROW_H);
        uint32_t col;
        /* WHICH SELECTION IS LIVE. Both lists keep a cursor at all times, so
         * two rows are always highlighted and only one of them answers to the
         * arrow keys. The focused side gets the full selection fill and the
         * other the fainter row shade -- the same two theme tokens the hover
         * state already uses, so a theme cannot end up with a focus cue it did
         * not choose a colour for. */
        if (at == navSel)
            aowl_ov_rect(x + 1.0f, ny, leftW + (float)AOWL_OV_PAD,
                         (float)AOWL_OV_ROW_H,
                         g_ov.navFocus ? AOWL_OV_SELBG : AOWL_OV_ROWALT);
        else if (hot)
            aowl_ov_rect(x + 1.0f, ny, leftW + (float)AOWL_OV_PAD,
                         (float)AOWL_OV_ROW_H, AOWL_OV_ROWALT);
        if (ci < 0) {
            /* Mods read in the panel's text colour; the SPT surface -- none of
             * it backed yet -- is dimmed, which is the same "not running"
             * language the manager uses. */
            col = Q->isMod ? AOWL_OV_TEXT : AOWL_OV_DIM;
            /* NO HAIRLINE HERE. It used to draw one above every root row to
             * say "this is the top of a branch"; the header comment above says
             * why the indentation says that better and why the rule said it
             * wrong. Deliberately nothing replaces it. */
            {
                /* A DISCLOSURE MARKER, and it is its own click target:
                 * pressing it opens or closes the page WITHOUT selecting it,
                 * which is what makes the tree browsable. Before this the top
                 * node could not be collapsed at all, so 802 settings across
                 * four levels sat permanently in front of every other page. */
                char lbl[96];
                int32_t kids = Q->isMod && pi == g_ov.selPage &&
                               g_ov.sCatCount > 1 &&
                               strcmp(g_ov.sItemsPage, Q->id) == 0;
                float mw = 2.0f * AOWL_OV_CW;
                int32_t hotM = kids && aowl_ov_hit(x + 1.0f, ny,
                                                   mw + (float)AOWL_OV_PAD,
                                                   (float)AOWL_OV_ROW_H);
                aowl_ov_fmt(lbl, (int32_t)sizeof(lbl), "%s%s",
                            !kids ? "  " : (g_ov.pageOpen[pi] ? "- " : "+ "),
                            Q->label);
                aowl_ov_textn(x + (float)AOWL_OV_PAD, ny + 3.0f, lbl, col,
                              (int32_t)((leftW - 34.0f) / AOWL_OV_CW));
                if (hotM && g_ov.clickDown) {
                    g_ov.pageOpen[pi] = !g_ov.pageOpen[pi];
                    InterlockedExchange(&g_ov.clickDown, 0);
                }
            }
            if (!Q->isMod)
                aowl_ov_text(x + (float)AOWL_OV_PAD + leftW - 18.0f, ny + 3.0f,
                             "NI", AOWL_OV_WARN);
        } else {
            /* A GROUP, and the whole job of this branch is that its DEPTH is
             * readable without counting leading spaces.
             *
             * Four things carry it, and they were all missing when every level
             * was drawn in one colour at two spaces of indent:
             *
             *  1. TREE GUIDES. A hairline column under each ancestor level and
             *     an elbow into the label. Rules, not glyphs: `|` and `+--` in
             *     an 8x16 bitmap font are as heavy as the text and read as
             *     content. A 1px rule reads as structure. Bounded by
             *     AOWL_OV_MAX_DEPTH, so at most twelve rects on a row.
             *  2. DEPTH IN THE COLOUR. Top level in the panel`s text colour,
             *     the level below dim, everything deeper faint -- so a glance
             *     down the column sorts the levels without reading any of them.
             *  3. AN EXPAND MARKER THAT MEANS SOMETHING. It used to be `+` on
             *     every node with children, expanded or not, which is a marker
             *     that says nothing. `-` now means "open, its children are the
             *     rows below", `+` means "closed, there is more in here", and a
             *     leaf has neither.
             *  4. AN ACCENT BAR on the selected row, at the left edge, so
             *     "where am I" is answered by a shape rather than by a shade of
             *     blue behind a row of text.
             *
             * Indent is three characters a level, not two, and is capped so the
             * name always keeps at least 14 columns -- past that the indent has
             * stopped conveying depth and started eating the only thing that
             * identifies the node. */
            AowlOvSCat* C = &g_ov.sCats[ci];
            char sub[128];
            int32_t d = C->depth < 1 ? 1 : C->depth;
            int32_t hasKids = (C->hi - C->lo) > C->direct;
            int32_t open = hasKids && aowl_ov_path_under(navSelFull, C->full);
            /* THE PAGE IS LEVEL 0 OF THIS TREE, and that is the fix.
             *
             * `ind` was `(d - 1) * step`, so a depth-1 group was drawn at
             * indent ZERO -- the same x as the PAGE row above it, which is
             * drawn at `x + AOWL_OV_PAD` with an identical two-character
             * marker prefix. The two were pixel-aligned. The guide loop
             * (`g = 1; g < d`) ran zero times at d == 1 and the elbow was
             * behind `if (d > 1)`, so the first level of nesting got no rule,
             * no elbow and no offset: "Singleplayer" and the group inside it
             * were indistinguishable, exactly as reported. Depths 2, 3 and 4
             * all worked, which is why this looked like a tree with one level
             * missing rather than a tree with a wrong origin.
             *
             * Indenting by `d * step` instead makes the page the root and every
             * group its descendant, so depth 1 gets the same three marks every
             * other level gets -- a rule under its parent, an elbow into its
             * label, and an offset from it. Nothing else moves. */
            float step = 3.0f * AOWL_OV_CW;
            float ind = (float)d * step;
            float lx, room;
            uint32_t lblCol;
            if (ind > leftW - 14.0f * AOWL_OV_CW - 30.0f)
                ind = leftW - 14.0f * AOWL_OV_CW - 30.0f;
            if (ind < 0.0f) ind = 0.0f;
            lx = x + (float)AOWL_OV_PAD + ind;
            /* The guides: one vertical rule per ancestor level -- the page
             * itself is one of them now, at g == 0 -- then an elbow into this
             * row`s own label. */
            {
                int32_t g;
                for (g = 0; g < d; g++) {
                    float gx = x + (float)AOWL_OV_PAD + (float)g * step + 3.0f;
                    if (gx >= lx) break;
                    aowl_ov_rect(gx, ny, 1.0f, (float)AOWL_OV_ROW_H,
                                 AOWL_OV_FAINT);
                }
                {
                    float ex = x + (float)AOWL_OV_PAD + (float)(d - 1) * step
                               + 3.0f;
                    if (ex < lx - 2.0f)
                        aowl_ov_rect(ex, ny + (float)AOWL_OV_ROW_H / 2.0f,
                                     lx - ex - 2.0f, 1.0f, AOWL_OV_FAINT);
                }
            }
            /* WHERE YOU ARE, in three marks, because one was not enough:
             * clicking a sub-page used to leave the PAGE row looking selected
             * and the sub-page looking like every other node, so the tree knew
             * the answer and did not show it.
             *
             *  * the SELECTED node keeps the full-width highlight drawn above
             *    and gets a solid accent bar;
             *  * every ANCESTOR of it gets a half-height accent tick, so the
             *    branch you are inside reads as the active path;
             *  * everything else gets neither.
             *
             * All three come from the same `navSelFull` the flattening, the
             * markers and the breadcrumb use, so they cannot disagree about
             * which node is current. */
            {
                int32_t isSel = (at == navSel);
                int32_t onPath = !isSel && navSelFull[0] &&
                                 aowl_ov_path_under(navSelFull, C->full);
                if (isSel)
                    aowl_ov_rect(x + 1.0f, ny, 3.0f, (float)AOWL_OV_ROW_H,
                                 AOWL_OV_ACCENT);
                else if (onPath)
                    aowl_ov_rect(x + 1.0f, ny + 5.0f, 3.0f,
                                 (float)(AOWL_OV_ROW_H - 10), AOWL_OV_HOT);
                lblCol = (isSel || onPath) ? AOWL_OV_TEXT
                       : (d == 1) ? AOWL_OV_TEXT
                       : (d == 2) ? AOWL_OV_DIM : AOWL_OV_FAINT;
            }
            room = leftW - 34.0f - ind;
            if (room < 8.0f * AOWL_OV_CW) room = 8.0f * AOWL_OV_CW;
            aowl_ov_fmt(sub, (int32_t)sizeof(sub), "%s%s",
                        !hasKids ? "  " : (open ? "- " : "+ "), C->label);
            aowl_ov_textn(lx, ny + 3.0f, sub, lblCol,
                          (int32_t)(room / AOWL_OV_CW));
            /* The marker is its own click target -- two characters wide, at
             * this node`s own indent -- so a branch can be opened without
             * being selected and selected without being opened. */
            if (hasKids && aowl_ov_hit(lx, ny, 2.0f * AOWL_OV_CW,
                                       (float)AOWL_OV_ROW_H) &&
                g_ov.clickDown) {
                g_ov.navOpen[ci] = !aowl_ov_nav_open(ci, navSelFull);
                /* Closing the branch the selection is inside would hide the
                 * selection, so the selection comes UP to the node being
                 * closed rather than disappearing off the tree. */
                if (!g_ov.navOpen[ci] && navSelFull[0] &&
                    aowl_ov_path_under(navSelFull, C->full) &&
                    strcmp(navSelFull, C->full) != 0) {
                    g_ov.selCat = ci;
                    g_ov.selItem = C->lo;
                    g_ov.topItem = C->lo;
                }
                InterlockedExchange(&g_ov.clickDown, 0);
            }
            aowl_ov_fmt(sub, (int32_t)sizeof(sub), "%d", C->hi - C->lo);
            aowl_ov_text(x + (float)AOWL_OV_PAD + leftW - 30.0f, ny + 3.0f,
                         sub, AOWL_OV_FAINT);
        }
        if (hot && g_ov.clickDown) {
            g_ov.selPage = pi;
            g_ov.selCat = ci;
            /* Selecting reveals: picking a page opens it, picking a node opens
             * it. A click that selects something and shows nothing new reads
             * as a click that did nothing at all. */
            g_ov.pageOpen[pi] = 1;
            if (ci >= 0) {
                g_ov.navOpen[ci] = 1;
                g_ov.selItem = g_ov.sCats[ci].lo;
                g_ov.topItem = g_ov.selItem;
            }
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        ny += (float)AOWL_OV_ROW_H;
    }

    /* --- THERE IS MORE OF THIS LIST --------------------------------------
     *
     * A list that scrolls and does not SAY it scrolls is a list whose extra
     * entries do not exist as far as the player is concerned -- which is
     * exactly the report this fixes. Two marks, both falsifiable by looking:
     *
     *  * a THUMB in the nav's own right-hand gutter, whose length is the
     *    fraction on screen and whose position is where in the list you are.
     *    Drawn only when there IS more, so its presence is itself the signal.
     *  * a COUNT at each end -- "12 more" above, "40 more" below -- because a
     *    thumb says "there is more" and a number says how much.
     *
     * Both come from `navCount`/`topPage`/`navRows`, the same three numbers the
     * row loop above just drew from, so the indicator cannot disagree with the
     * list it describes. */
    if (navCount > navRows) {
        float trackX = x + (float)AOWL_OV_PAD + leftW + 1.0f;
        float trackY = y + (float)AOWL_OV_LINE_H;
        float trackH = (float)navRows * (float)AOWL_OV_ROW_H;
        float th = trackH * (float)navRows / (float)navCount;
        float tt = trackH * (float)g_ov.topPage / (float)navCount;
        char more[32];
        if (th < 12.0f) th = 12.0f;
        if (tt > trackH - th) tt = trackH - th;
        if (tt < 0.0f) tt = 0.0f;
        aowl_ov_rect(trackX, trackY, 3.0f, trackH, AOWL_OV_PANEBG);
        aowl_ov_rect(trackX, trackY + tt, 3.0f, th, AOWL_OV_ACCENT);
        if (g_ov.topPage > 0) {
            aowl_ov_fmt(more, (int32_t)sizeof(more), "^ %d more", g_ov.topPage);
            /* Right-aligned in the nav's own column, beside the "mods"
             * caption rather than on top of it. */
            aowl_ov_text(x + (float)AOWL_OV_PAD + leftW
                           - (float)strlen(more) * AOWL_OV_CW, y,
                         more, AOWL_OV_FAINT);
        }
        {
            int32_t below = navCount - g_ov.topPage - navRows;
            if (below > 0) {
                aowl_ov_fmt(more, (int32_t)sizeof(more), "v %d more", below);
                aowl_ov_text(x + (float)AOWL_OV_PAD + leftW
                               - (float)strlen(more) * AOWL_OV_CW,
                             trackY + trackH - (float)AOWL_OV_LINE_H + 2.0f,
                             more, AOWL_OV_FAINT);
            }
        }
    }

    /* --- the right pane header ------------------------------------------- */
    P = (g_ov.selPage < pc) ? &g_ov.sPages[g_ov.selPage] : NULL;
    loaded = (P && strcmp(g_ov.sItemsPage, P->id) == 0 && !g_ov.sItemsErr);
    cy = y;
    {
        char hdr[192];
        if (!P) {
            aowl_ov_text(rx, cy, "settings", AOWL_OV_FAINT);
        } else if (g_ov.sItemsErr && strcmp(g_ov.sItemsPage, P->id) == 0) {
            aowl_ov_fmt(hdr, (int32_t)sizeof(hdr), "%s", P->label);
            aowl_ov_textn(rx, cy, hdr, AOWL_OV_ACCENT, rcols);
        } else if (!loaded) {
            aowl_ov_fmt(hdr, (int32_t)sizeof(hdr), "%s   loading...", P->label);
            aowl_ov_textn(rx, cy, hdr, AOWL_OV_DIM, rcols);
        } else if (P->isMod) {
            if (g_ov.selCat >= 0 && g_ov.selCat < g_ov.sCatCount) {
                /* THE BREADCRUMB. Built by walking `parent` up from the
                 * selected node, so it is the tree`s own structure printed out
                 * rather than a second derivation of it -- if the walk did not
                 * terminate at a top-level node the breadcrumb would be short,
                 * which is exactly what `aowl_ov_cats_wellformed` refuses to
                 * let happen. Page first, then every ancestor, then the node:
                 * "Singleplayer > Player > Health > Regeneration". */
                AowlOvSCat* C = &g_ov.sCats[g_ov.selCat];
                int32_t chain[AOWL_OV_MAX_DEPTH + 1];
                int32_t nc = 0, c = g_ov.selCat, k;
                char crumb[192], tail[96], cnt[48];
                int32_t room, cw;
                float bx;
                while (c >= 0 && c < g_ov.sCatCount && nc <= AOWL_OV_MAX_DEPTH) {
                    chain[nc++] = c;
                    c = g_ov.sCats[c].parent;
                }
                /* THE BREADCRUMB, IN TWO PIECES, and the split is the point.
                 *
                 * As one string clipped on the right, a deep path lost its own
                 * tail -- "Singleplayer > Player > Health > Regen.." threw away
                 * the only segment that says where you are and kept the four
                 * that say where you came from. So the LAST segment is drawn
                 * separately, in the panel`s brightest colour, and is never
                 * truncated; the ancestors are dim, and when they do not fit
                 * they are cut FROM THE LEFT and marked `..`, which is the end
                 * that carries least.
                 *
                 * The count moves to the right edge instead of trailing the
                 * path, so it stops competing with the name for the same
                 * pixels and lands in the same place on every page. */
                aowl_ov_copy(crumb, (int32_t)sizeof(crumb), P->label);
                for (k = nc - 1; k >= 1; k--) {
                    int32_t L = (int32_t)strlen(crumb);
                    _snprintf(crumb + L, sizeof(crumb) - 1 - (size_t)L, " > %s",
                              g_ov.sCats[chain[k]].label);
                    crumb[sizeof(crumb) - 1] = 0;
                }
                aowl_ov_fmt(tail, (int32_t)sizeof(tail), " > %s", C->label);
                aowl_ov_fmt(cnt, (int32_t)sizeof(cnt), "%d of %d settings",
                            C->hi - C->lo, g_ov.sItemCount);
                cw = (int32_t)strlen(cnt);
                /* What the ancestors may have: the pane, less the tail, less
                 * the count and a gap. */
                room = rcols - (int32_t)strlen(tail) - cw - 4;
                if (room < 6) room = 6;
                if ((int32_t)strlen(crumb) > room) {
                    /* Cut from the LEFT, on a separator where there is one, so
                     * the crumb never starts mid-word. */
                    char* from = crumb + (int32_t)strlen(crumb) - (room - 3);
                    char* sep = strstr(from, "> ");
                    if (sep) from = sep + 2;
                    memmove(crumb + 3, from, strlen(from) + 1);
                    crumb[0] = OV_DOT; crumb[1] = OV_DOT; crumb[2] = OV_SP;
                }
                bx = aowl_ov_text(rx, cy, crumb, AOWL_OV_DIM);
                bx = aowl_ov_text(bx, cy, tail, AOWL_OV_TEXT);
                aowl_ov_text(rrEdge - (float)cw * AOWL_OV_CW, cy, cnt,
                             AOWL_OV_FAINT);
                hdr[0] = 0;
            } else {
                aowl_ov_fmt(hdr, (int32_t)sizeof(hdr),
                            "%s   --   %d settings, %d implemented", P->label,
                            g_ov.sItemCount, g_ov.sItemsImpl);
            }
            if (hdr[0]) aowl_ov_textn(rx, cy, hdr, AOWL_OV_ACCENT, rcols);
        } else {
            aowl_ov_fmt(hdr, (int32_t)sizeof(hdr),
                        "%s   --   %d values, none implemented yet", P->label,
                        g_ov.sItemCount);
            aowl_ov_textn(rx, cy, hdr, AOWL_OV_WARN, rcols);
        }
    }
    cy += (float)AOWL_OV_LINE_H + 2.0f;

    /* --- THE SEARCH BOX -- the primary way into 802 rows ------------------
     *
     * Permanent, full width, two lines. It is drawn on every settings frame,
     * loaded or not, before any early return below -- a search box that
     * appears only once a page has loaded is a search box the player has to
     * learn is there. `/` focuses it, clicking it focuses it, ESC clears and
     * unfocuses, ENTER/DOWN moves into the results.
     *
     * The second line says WHAT IT SEARCHED, always: how many rows are on the
     * page and which fields were looked at. The panel must not leave the
     * player guessing whether a term that found nothing found nothing because
     * it is not there or because that field is not searched. */
    {
        float bh = (float)AOWL_OV_SEARCH_BOX;
        int32_t hot = aowl_ov_hit(rx - 2.0f, cy, rw, bh);
        int32_t on = g_ov.searchFocus;
        char line[224];
        aowl_ov_rect(rx - 2.0f, cy, rw, bh,
                     on ? AOWL_OV_SELBG : (hot ? AOWL_OV_HOT : AOWL_OV_PANEBG));
        /* A two-pixel frame when focused, one when not: the field says where
         * the keyboard is going without needing a blinking caret to be read. */
        aowl_ov_frame_rect(rx - 2.0f, cy, rw, bh, on ? 2.0f : 1.0f,
                           on ? AOWL_OV_ACCENT : AOWL_OV_EDGE);
        /* The magnifier stands in for an icon this font does not have. It is
         * always in the same place, so the eye finds the field by shape. */
        aowl_ov_text(rx + 6.0f, cy + 3.0f, "[/]",
                     on ? AOWL_OV_ACCENT : AOWL_OV_DIM);
        if (g_ov.search[0])
            aowl_ov_fmt(line, (int32_t)sizeof(line), "%s%s", g_ov.search,
                        on ? "_" : "");
        else
            aowl_ov_fmt(line, (int32_t)sizeof(line), "%s",
                        on ? "_"
                           : "search these settings by name, key or group");
        aowl_ov_textn(rx + 6.0f + 4.0f * AOWL_OV_CW, cy + 3.0f, line,
                      g_ov.search[0] ? AOWL_OV_TEXT : AOWL_OV_FAINT,
                      (int32_t)((rw - 12.0f - 4.0f * AOWL_OV_CW) / AOWL_OV_CW));
        /* A clear affordance, so a term can be dropped with the mouse too. */
        if (g_ov.search[0]) {
            float cxx = rrEdge - 3.0f * AOWL_OV_CW;
            int32_t hotC = aowl_ov_hit(cxx - 2.0f, cy, 3.0f * AOWL_OV_CW, bh);
            aowl_ov_text(cxx, cy + 3.0f, "[x]",
                         hotC ? AOWL_OV_TEXT : AOWL_OV_DIM);
            if (hotC && g_ov.clickDown) {
                g_ov.search[0] = 0; g_ov.searchFocus = 0;
                InterlockedExchange(&g_ov.clickDown, 0);
            }
        }
        if (hot && g_ov.clickDown) {
            g_ov.searchFocus = 1;
            /* Taking the keyboard for the search box ABANDONS an open value or
             * string box. The alternative is two focused fields, and the one
             * that draws a caret is then not the one receiving the keys --
             * which is the same class of defect as the search box eating `-`
             * and `=`, just harder to see. Abandon rather than commit: the
             * player clicked somewhere else, they did not press ENTER. */
            g_ov.editItem = -1;
            g_ov.capturing = 0;
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        /* The scope line, and it is MEASURED against the pane rather than
         * written and hoped for: a sentence that runs off the right edge is
         * the same as no sentence, and this one is the panel`s only statement
         * of what search does and does not reach. The long form is used when
         * it fits and a short form when it does not, and both name the same
         * three fields -- what gets dropped is prose, never a field. */
        {
            const char* longF = aowl_ov_searching()
                ? "%d of %d rows  --  name, key, group only"
                : "%d rows  --  searches name, key, group only";
            if (aowl_ov_searching())
                aowl_ov_fmt(line, (int32_t)sizeof(line), longF,
                            g_ov.filtCount, g_ov.sItemCount);
            else
                aowl_ov_fmt(line, (int32_t)sizeof(line), longF,
                            g_ov.sItemCount);
            if ((int32_t)strlen(line) + 44 <= rcols) {
                int32_t L = (int32_t)strlen(line);
                _snprintf(line + L, sizeof(line) - 1 - (size_t)L,
                          "  (not descriptions, values or other pages)");
                line[sizeof(line) - 1] = 0;
            }
        }
        aowl_ov_textn(rx + 2.0f, cy + bh + 3.0f, line,
                      (aowl_ov_searching() && g_ov.filtCount == 0)
                          ? AOWL_OV_WARN
                          : (aowl_ov_searching() ? AOWL_OV_ACCENT
                                                 : AOWL_OV_FAINT),
                      rcols);
    }
    cy += (float)AOWL_OV_SEARCH_H;

    if (P && g_ov.sItemsErr && strcmp(g_ov.sItemsPage, P->id) == 0) {
        /* The reason the WORKER recorded, not a guess made here. The old text
         * asserted "the mod may not be loaded" for every failure, including the
         * one that was actually a full buffer -- a confidently wrong diagnostic,
         * which is worse than none. */
        aowl_ov_wrap(rx, cy,
                     g_ov.sItemsWhy[0] ? g_ov.sItemsWhy
                                       : "could not read this page's settings.",
                     AOWL_OV_ERR, rcols, 5);
        return;
    }
    if (!loaded) return;

    /* THE LAST WRITE DID NOT TAKE, SAID OUT LOUD.
     *
     * Drawn, deliberately, WITHOUT returning: the rows stay visible underneath
     * so the player can see the control that snapped back and the sentence that
     * explains it at the same time. A setting that reverts silently is the exact
     * failure that reached a user; this is the line that makes it impossible to
     * miss. Cleared by the next write that verifies, and by loading any page. */
    if (g_ov.sWriteWhy[0]) {
        int32_t wlines = aowl_ov_wrap(rx, cy, g_ov.sWriteWhy,
                                      AOWL_OV_ERR, rcols, 3);
        cy += (float)(wlines * AOWL_OV_LINE_H) + 2.0f;
    }

    /* --- the controls ---------------------------------------------------- */
    {
        int32_t n = g_ov.sItemCount;
        float itemsBottom = y + bodyH - (float)AOWL_OV_SDETAIL_H;

        /* `items` is sorted by the whole path, so the selected nav node -- at
         * ANY depth -- is a contiguous half-open range and the filter is still
         * a pair of bounds. `selItem` stays an ITEM index throughout, which is
         * why the edit, drag and commit paths below and in
         * `aowl_ov_settings_key` need to know nothing about the tree, and
         * nothing about search either. */
        int32_t base[160];
        const char* baseFull = "";
        (void)base;
        lo = 0; hi = n;
        if (g_ov.selCat >= 0 && g_ov.selCat < g_ov.sCatCount) {
            lo = g_ov.sCats[g_ov.selCat].lo;
            hi = g_ov.sCats[g_ov.selCat].hi;
            baseFull = g_ov.sCats[g_ov.selCat].full;
            if (lo < 0) lo = 0;
            if (hi > n) hi = n;
            if (hi < lo) hi = lo;
        }
        g_ov.viewLo = lo; g_ov.viewHi = hi;

        /* A FREE SCROLL ENDS WHEN THE SELECTION MOVES, which is when following
         * it is what a person expects again -- `navSelSeen``s rule, applied to
         * the control list. Detected by change rather than set at every site
         * that can move `selItem`: there are a dozen of those and a new one
         * that forgot to clear the flag would leave the list stuck. */
        if (g_ov.selItem != g_ov.itemSelSeen) {
            g_ov.itemFree = 0; g_ov.itemSelSeen = g_ov.selItem;
        }

        aowl_ov_search_refresh();

        if (aowl_ov_searching()) {
            /* Search overrides the nav`s range: the rows on screen are the
             * matches, wherever on the page they live. `selItem` is snapped to
             * a MATCH so that the arrow keys, the detail strip and every edit
             * path keep pointing at a row that is actually drawn. */
            int32_t at;
            if (g_ov.filtCount <= 0) {
                aowl_ov_wrap(rx, cy,
                             "nothing on this page matches. the box searches "
                             "setting names, keys and group names -- not "
                             "descriptions, not values, and not other pages.",
                             AOWL_OV_WARN, rcols, 3);
                goto controls_done;
            }
            at = aowl_ov_filt_pos(g_ov.selItem);
            if (at < 0) at = 0;
            g_ov.selItem = g_ov.filt[at];
            /* FOLLOWING THE CURSOR, UNLESS THE PLAYER HAS JUST SCROLLED -- the
             * same rule the nav uses a few hundred lines up, and for the same
             * reason: without it the wheel moved `topItem` and this clamp put
             * it straight back, so the list could not be scrolled away from
             * its own selection at all. The RANGE clamps below still run
             * either way, because a free scroll can leave the view past the
             * end of the list and blank rows read as a broken screen. */
            if (!g_ov.itemFree) {
                if (g_ov.topItem > at) g_ov.topItem = at;
                if (at - g_ov.topItem >= iRows) g_ov.topItem = at - iRows + 1;
            }
            if (g_ov.topItem > g_ov.filtCount - iRows)
                g_ov.topItem = g_ov.filtCount - iRows;
            if (g_ov.topItem < 0) g_ov.topItem = 0;
        } else {
            if (g_ov.selItem >= hi) g_ov.selItem = hi > lo ? hi - 1 : lo;
            if (g_ov.selItem < lo) g_ov.selItem = lo;
            if (!g_ov.itemFree) {
                if (g_ov.topItem > g_ov.selItem) g_ov.topItem = g_ov.selItem;
                if (g_ov.selItem - g_ov.topItem >= iRows)
                    g_ov.topItem = g_ov.selItem - iRows + 1;
            }
            if (g_ov.topItem > hi - iRows) g_ov.topItem = hi - iRows;
            if (g_ov.topItem < lo) g_ov.topItem = lo;
        }

        if (n == 0 && g_ov.sHiddenCount > 0) {
            /* A page emptied BY THE FILTER is not a page with nothing in it,
             * and saying "this page declares no settings" about one would be
             * the panel lying about its own doing. It names the number and the
             * key that brings them back -- the only honest form of a hidden
             * thing is one that says it is hidden. */
            char msg[192];
            aowl_ov_fmt(msg, (int32_t)sizeof(msg),
                        "every setting on this page is not implemented yet "
                        "(%d hidden). F8 shows them, read-only.",
                        g_ov.sHiddenCount);
            aowl_ov_wrap(rx, cy, msg, AOWL_OV_DIM, rcols, 3);
        } else if (n == 0)
            aowl_ov_text(rx, cy, "this page declares no settings", AOWL_OV_DIM);
        else if (g_ov.sItemsWhy[0])
            aowl_ov_text(rx, y + bodyH - (float)AOWL_OV_SDETAIL_H
                             - (float)AOWL_OV_LINE_H,
                         g_ov.sItemsWhy, AOWL_OV_WARN);

        /* The row walk. `ry` advances by hand rather than by `i * ROW_H`
         * because a GROUP HEADER is a line of its own: the loop is over rows,
         * the height of a row is not constant any more, and the stop condition
         * is "the next row would not fit" rather than a count. `iRows` is still
         * what PgUp/PgDn moves by and is still a count of CONTROL rows, so the
         * page key can overshoot the bottom of a header-heavy screen by a row
         * or two -- which the scroll clamp then corrects on the next frame.
         *
         * In search mode `i` indexes `filt` instead of the range; everything
         * below still works in item indices. */
        {
        float ry = cy;
        int32_t total = aowl_ov_searching() ? g_ov.filtCount : (hi - lo);
        (void)total;
        for (i = 0; ; i++) {
            int32_t at;
            AowlOvSItem* si;
            int32_t isSel, canEdit, rowHot, newGroup;
            uint32_t lblCol;
            float cx, cyy, rowX;
            if (aowl_ov_searching()) {
                if (g_ov.topItem + i >= g_ov.filtCount) break;
                at = g_ov.filt[g_ov.topItem + i];
            } else {
                at = g_ov.topItem + i;
                if (at >= hi) break;
            }
            si = &g_ov.sItems[at];

            /* --- THE GROUP HEADER ---------------------------------------
             *
             * Drawn before the first row on screen and wherever the group
             * changes, and it always carries a NAME -- `aowl_ov_group_title`
             * has no branch that yields an empty string. This is the whole of
             * defect 1: there used to be a hairline here and nothing else, so
             * a page told the player that its rows were divided and never into
             * what.
             *
             * Suppressed entirely in search mode: results come from all over
             * the page, so a per-row header would be one header per row. Each
             * result carries its group on the row instead -- see below. */
            newGroup = !aowl_ov_searching() &&
                       (i == 0 || !aowl_ov_same_group(si, &g_ov.sItems[at - 1]));
            if (newGroup) {
                /* A BAND, not a hairline.
                 *
                 * A rule between two groups says only that a boundary exists,
                 * and at four levels of nesting a screenful of rules says
                 * nothing at all -- which is what "the sub-sub-pages are messy"
                 * was about. A filled band with the name in it reads as a
                 * container: the rows below it are visibly inside something.
                 *
                 * The band carries its own count on the right, in the same
                 * column the nav uses, so the two agree by construction; and
                 * the rows beneath are indented past it, so the header is the
                 * outer thing and the rows are the inner ones. Six pixels of
                 * lead above it separates one group from the previous group`s
                 * last row -- the crowding the report named. */
                char gt[160], gc[24];
                int32_t gn = 0, q;
                if (ry + (float)AOWL_OV_GHDR_H + 12.0f + (float)AOWL_OV_ROW_H
                        > itemsBottom) break;
                aowl_ov_group_title(si, baseFull, gt, (int32_t)sizeof(gt));
                for (q = at; q < hi && aowl_ov_same_group(si, &g_ov.sItems[q]);
                     q++) gn++;
                /* Real air between regions. Six pixels was a gap; twelve is a
                 * SEPARATION, and the difference is whether two groups read as
                 * one list with a caption in it or as two things. The first
                 * band on screen does not get it -- leading above the first
                 * item is just a misaligned pane. */
                ry += (i == 0) ? 2.0f : 12.0f;
                aowl_ov_rect(rx - 2.0f, ry - 2.0f, rw,
                             (float)AOWL_OV_LINE_H + 2.0f, AOWL_OV_PANEBG);
                aowl_ov_rect(rx - 2.0f, ry - 2.0f, 2.0f,
                             (float)AOWL_OV_LINE_H + 2.0f, AOWL_OV_ACCENT);
                aowl_ov_fmt(gc, (int32_t)sizeof(gc), "%d", gn);
                aowl_ov_textn(rx + 6.0f, ry, gt, AOWL_OV_ACCENT,
                              rcols - (int32_t)strlen(gc) - 3);
                aowl_ov_text(rrEdge - (float)strlen(gc) * AOWL_OV_CW, ry,
                             gc, AOWL_OV_FAINT);
                ry += (float)AOWL_OV_LINE_H;
            }
            if (ry + (float)AOWL_OV_ROW_H > itemsBottom) break;

            isSel = (at == g_ov.selItem);
            /* A ROW BEING WRITTEN IS DISABLED, not merely annotated. The
             * request the user asked for: "while we are sending the request we
             * should completely gray out / disable the value". Every widget
             * below already draws itself dim and ignores clicks when `canEdit`
             * is 0, so one term here greys the control, the slider, the toggle
             * and the value box together and makes a second edit on top of an
             * unconfirmed one unrepresentable. In the normal case this is a
             * flicker: the edit kick means the confirmation arrives in one
             * round trip, not in five seconds. */
            canEdit = si->implemented && P->isMod && si->kind != AOWL_S_NESTED
                      && si->pend != AOWL_OV_PEND_SAVING;
            lblCol = !si->implemented ? AOWL_OV_DIM
                   : si->pend == AOWL_OV_PEND_SAVING ? AOWL_OV_DIM
                                                     : AOWL_OV_TEXT;
            cx = ctlX; cyy = ry + 3.0f;
            rowX = rx + (aowl_ov_searching() ? 0.0f : 10.0f);
            rowHot = aowl_ov_hit(rx - 2.0f, ry, rw, (float)AOWL_OV_ROW_H);

            /* The other half of the focus cue -- see the nav`s selection fill. */
            if (isSel)
                aowl_ov_rect(rx - 2.0f, ry, rw, (float)AOWL_OV_ROW_H,
                             g_ov.navFocus ? AOWL_OV_ROWALT : AOWL_OV_SELBG);
            else if (rowHot && canEdit)
                aowl_ov_rect(rx - 2.0f, ry, rw, (float)AOWL_OV_ROW_H, AOWL_OV_ROWALT);

            /* Indented past the group band above, so the hierarchy is a shape
             * and not something the player has to infer from the header text.
             * `rowX`, not `rx`, everywhere the label column is used below. */
            /* THE THIRD STATE, ON THE ROW. A player must be able to tell
             * "saving" from "saved" from "rejected" without reading a banner
             * at the bottom of the panel. `NI` (unimplemented) can never
             * collide here: an unimplemented row is not editable, so it can
             * never carry a pending edit.
             *
             * IT LIVES IN THE LABEL COLUMN, right-aligned against `ctlX`, and
             * the label is truncated to make room for it. It used to be drawn
             * at `rrEdge` -- the RIGHT edge of the row -- which is inside the
             * control column: every widget below draws from `ctlX` rightwards
             * and every one of them is drawn AFTER this, so the badge was
             * painted over by the slider/value box and was, exactly as
             * reported, invisible or overlapping. The label column is the only
             * horizontal band on the row that no control ever occupies, so the
             * badge is legible at every panel width; when the column is too
             * narrow to hold both, the LABEL gives way (truncated with the
             * same ellipsis every other narrow label uses) rather than the
             * badge, because a state nobody can see is the failure and a
             * shortened label is not. */
            {
                const char* bt = si->pend == AOWL_OV_PEND_NONE      ? ""
                               : si->pend == AOWL_OV_PEND_SAVING    ? "SAVING"
                               : si->pend == AOWL_OV_PEND_REJECTED  ? "NOT SAVED"
                                                                    : "UNCONFIRMED";
                uint32_t bc = si->pend == AOWL_OV_PEND_SAVING   ? AOWL_OV_ACCENT
                            : si->pend == AOWL_OV_PEND_REJECTED ? AOWL_OV_ERR
                                                                : AOWL_OV_WARN;
                float bw = (float)strlen(bt) * AOWL_OV_CW;
                float lblRight = ctlX - 8.0f - (bt[0] ? bw + AOWL_OV_CW : 0.0f);
                int32_t lblCols = (int32_t)((lblRight - rowX) / AOWL_OV_CW);
                if (lblCols < 1) lblCols = 1;
                aowl_ov_textn(rowX, cyy, si->label, lblCol, lblCols);
                if (bt[0])
                    aowl_ov_text(ctlX - 8.0f - bw, ry + 3.0f, bt, bc);
            }

            /* Clicking any editable row selects it, so the keyboard follows the
             * mouse. The controls below may also consume the click. */
            if (rowHot && g_ov.clickDown) g_ov.selItem = at;

            switch (si->kind) {
            case AOWL_S_BOOL: {
                float bw = 52.0f, bh = (float)(AOWL_OV_ROW_H - 6);
                int32_t on = (si->raw[0] == 't' || si->raw[0] == '1');
                int32_t hot = canEdit && aowl_ov_hit(cx, ry + 3.0f, bw, bh);
                aowl_ov_rect(cx, ry + 3.0f, bw, bh,
                             hot ? AOWL_OV_HOT
                                 : (!canEdit ? AOWL_OV_ROWALT
                                    : (on ? AOWL_OV_ON : AOWL_OV_OFF)));
                aowl_ov_frame_rect(cx, ry + 3.0f, bw, bh, 1.0f,
                                   canEdit ? AOWL_OV_EDGE : AOWL_OV_FAINT);
                aowl_ov_text(cx + (on ? 16.0f : 13.0f), ry + 4.0f,
                             on ? "ON" : "OFF",
                             canEdit ? AOWL_OV_TEXT : AOWL_OV_FAINT);
                if (hot && g_ov.clickDown) {
                    g_ov.selItem = at;
                    InterlockedExchange(&g_ov.clickDown, 0);
                    aowl_ov_s_toggle_bool(si);
                }
                break;
            }
            case AOWL_S_INT:
            case AOWL_S_FLOAT: {
                if (si->hasRange) {
                    /* THE TRACK GIVES UP 20 PIXELS TO THE VALUE.
                     *
                     * At 104 the value cell was `ctlW - 104 - 8` = 44 px, which
                     * is FIVE characters. Measured: a row holding 543210
                     * rendered `54321`. That was survivable while every ranged
                     * row was 0..100, and stops being so the moment the value
                     * box lets a number be typed -- a field that silently drops
                     * the digit you just entered is worse than no field. 84
                     * leaves eight columns, enough for a six-digit integer or
                     * a signed four-digit one, and costs the track a fifth of
                     * its length. */
                    float sw = 84.0f, sh = 4.0f;
                    float sy = ry + (float)AOWL_OV_ROW_H / 2.0f - sh / 2.0f;
                    float cur = (g_ov.dragItem == at) ? g_ov.dragVal
                                                      : (float)strtod(si->raw, NULL);
                    float t = (cur - si->lo) / (si->hi - si->lo);
                    uint32_t fill = canEdit ? AOWL_OV_ACCENT : AOWL_OV_FAINT;
                    if (t < 0.0f) t = 0.0f; if (t > 1.0f) t = 1.0f;
                    aowl_ov_rect(cx, sy, sw, sh, AOWL_OV_PANEBG);
                    aowl_ov_rect(cx, sy, sw * t, sh, fill);
                    aowl_ov_rect(cx + sw * t - 3.0f, ry + 4.0f, 6.0f,
                                 (float)(AOWL_OV_ROW_H - 8),
                                 canEdit ? AOWL_OV_TEXT : AOWL_OV_FAINT);
                    /* THE VALUE IS A TYPE BOX. See `aowl_ov_s_num_box`. */
                    aowl_ov_s_num_box(si, at, cx + sw + 8.0f, ry,
                                      rrEdge - (cx + sw + 8.0f), canEdit);
                    if (canEdit && g_ov.editItem != at) {
                        int32_t hot = aowl_ov_hit(cx - 4.0f, ry, sw + 8.0f,
                                                  (float)AOWL_OV_ROW_H);
                        if (g_ov.mouseHeld && (hot || g_ov.dragItem == at)) {
                            float nt = (mxp - cx) / sw;
                            float nv;
                            if (nt < 0.0f) nt = 0.0f; if (nt > 1.0f) nt = 1.0f;
                            nv = si->lo + nt * (si->hi - si->lo);
                            if (si->step > 0.0f)
                                nv = si->lo +
                                     (float)((int32_t)((nv - si->lo) / si->step +
                                                       0.5f)) * si->step;
                            if (nv < si->lo) nv = si->lo;
                            if (nv > si->hi) nv = si->hi;
                            g_ov.dragItem = at;
                            g_ov.selItem = at;
                            g_ov.dragVal = nv;
                            aowl_ov_s_fmt_num(si, nv);
                            /* ARM the write slot, every frame of the drag, and
                             * let the quiet period decide when it goes out.
                             *
                             * The old code deliberately did NOT commit here and
                             * committed once on release instead -- which is the
                             * same number of writes and is why this looked
                             * already-coalesced. It was not equivalent: the
                             * release branch only ran while the row was still
                             * drawn and still editable, so a release after a
                             * scroll dropped the write ENTIRELY and the file
                             * kept the old value while the row showed the new
                             * one. Arming here has no such precondition, and
                             * `aowl_ov_s_commit` collapses every frame of the
                             * drag into the one slot, so a 200-frame drag is
                             * still one POST. */
                            aowl_ov_s_commit(si);
                            InterlockedExchange(&g_ov.clickDown, 0);
                        }
                    }
                } else {
                    /* No range: a value with a minus/plus pair. */
                    float bw = 20.0f, bh = (float)(AOWL_OV_ROW_H - 6);
                    float minusX = cx, plusX = cx + ctlW - bw;
                    int32_t hm = canEdit && aowl_ov_hit(minusX, ry + 3.0f, bw, bh);
                    int32_t hp = canEdit && aowl_ov_hit(plusX, ry + 3.0f, bw, bh);
                    aowl_ov_rect(minusX, ry + 3.0f, bw, bh,
                                 hm ? AOWL_OV_HOT : AOWL_OV_ROWALT);
                    aowl_ov_frame_rect(minusX, ry + 3.0f, bw, bh, 1.0f,
                                       canEdit ? AOWL_OV_EDGE : AOWL_OV_FAINT);
                    aowl_ov_text(minusX + 6.0f, ry + 4.0f, "-",
                                 canEdit ? AOWL_OV_TEXT : AOWL_OV_FAINT);
                    aowl_ov_rect(plusX, ry + 3.0f, bw, bh,
                                 hp ? AOWL_OV_HOT : AOWL_OV_ROWALT);
                    aowl_ov_frame_rect(plusX, ry + 3.0f, bw, bh, 1.0f,
                                       canEdit ? AOWL_OV_EDGE : AOWL_OV_FAINT);
                    aowl_ov_text(plusX + 6.0f, ry + 4.0f, "+",
                                 canEdit ? AOWL_OV_TEXT : AOWL_OV_FAINT);
                    aowl_ov_s_num_box(si, at, minusX + bw + 8.0f, ry,
                                      plusX - (minusX + bw + 8.0f), canEdit);
                    if (hm && g_ov.clickDown) {
                        g_ov.selItem = at; InterlockedExchange(&g_ov.clickDown, 0);
                        aowl_ov_s_adjust(si, -1);
                    } else if (hp && g_ov.clickDown) {
                        g_ov.selItem = at; InterlockedExchange(&g_ov.clickDown, 0);
                        aowl_ov_s_adjust(si, +1);
                    }
                }
                break;
            }
            case AOWL_S_ENUM: {
                float bw = 16.0f;
                float lX = cx, rX = cx + ctlW - bw;
                int32_t hl = canEdit && aowl_ov_hit(lX, ry + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6));
                int32_t hr = canEdit && aowl_ov_hit(rX, ry + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6));
                aowl_ov_text(lX, ry + 3.0f, "<", canEdit ? (hl ? AOWL_OV_ACCENT : AOWL_OV_TEXT) : AOWL_OV_FAINT);
                aowl_ov_text(rX, ry + 3.0f, ">", canEdit ? (hr ? AOWL_OV_ACCENT : AOWL_OV_TEXT) : AOWL_OV_FAINT);
                aowl_ov_textn(lX + bw + 4.0f, cyy, si->value[0] ? si->value : "-",
                              canEdit ? AOWL_OV_TEXT : AOWL_OV_DIM,
                              (int32_t)((rX - (lX + bw + 4.0f)) / AOWL_OV_CW));
                if (hl && g_ov.clickDown) {
                    g_ov.selItem = at; InterlockedExchange(&g_ov.clickDown, 0);
                    aowl_ov_s_cycle_enum(si, -1);
                } else if (hr && g_ov.clickDown) {
                    g_ov.selItem = at; InterlockedExchange(&g_ov.clickDown, 0);
                    aowl_ov_s_cycle_enum(si, +1);
                }
                break;
            }
            case AOWL_S_STRING:
            case AOWL_S_KEYBIND: {
                int32_t editing = (g_ov.editItem == at);
                float bw = ctlW;
                const char* shown = editing ? g_ov.editBuf : si->value;
                uint32_t bcol = editing ? AOWL_OV_SELBG
                               : (!canEdit ? AOWL_OV_PANEBG : AOWL_OV_ROWALT);
                int32_t hot = canEdit && aowl_ov_hit(cx, ry + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6));
                aowl_ov_rect(cx, ry + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6), bcol);
                aowl_ov_frame_rect(cx, ry + 3.0f, bw, (float)(AOWL_OV_ROW_H - 6), 1.0f,
                                   canEdit ? AOWL_OV_EDGE : AOWL_OV_FAINT);
                if (editing && si->kind == AOWL_S_KEYBIND)
                    aowl_ov_text(cx + 5.0f, ry + 4.0f, "press a key...", AOWL_OV_WARN);
                else {
                    char tb[80];
                    aowl_ov_fmt(tb, (int32_t)sizeof(tb), "%s%s",
                                shown[0] ? shown : (editing ? "" : "-"),
                                editing && si->kind == AOWL_S_STRING ? "_" : "");
                    aowl_ov_textn(cx + 5.0f, ry + 4.0f, tb,
                                  canEdit ? AOWL_OV_TEXT : AOWL_OV_DIM,
                                  (int32_t)((bw - 8.0f) / AOWL_OV_CW));
                }
                if (hot && g_ov.clickDown) {
                    g_ov.selItem = at;
                    InterlockedExchange(&g_ov.clickDown, 0);
                    g_ov.editItem = at;
                    if (si->kind == AOWL_S_KEYBIND) g_ov.capturing = 1;
                    else {
                        g_ov.capturing = 0;
                        aowl_ov_copy(g_ov.editBuf, (int32_t)sizeof(g_ov.editBuf),
                                     si->value);
                    }
                }
                break;
            }
            case AOWL_S_NESTED:
            default:
                aowl_ov_textn(cx, cyy, si->value[0] ? si->value : "raw JSON",
                              AOWL_OV_FAINT,
                              (int32_t)((rrEdge - cx) / AOWL_OV_CW));
                break;
            }

            /* The not-implemented badge, right at the row's edge -- the one
             * mark the user asked to be unmistakable. */
            if (!si->implemented)
                aowl_ov_text(rrEdge - 3.0f * AOWL_OV_CW, ry + 3.0f, "NI",
                             AOWL_OV_WARN);

            /* WHERE the hit is. A result list with no path is ambiguous
             * exactly when it matters -- "Enabled" occurs in nine groups on a
             * real page -- so every result carries its own breadcrumb, dimmed,
             * under the label. It costs the row nothing: it is drawn in the
             * label`s own band, right-aligned into the gap before the control.
             */
            if (aowl_ov_searching()) {
                /* Cut from the LEFT, and in the same `>` vocabulary the header
                 * uses. Clipped on the right it read
                 * `Player/Health/Regenera..` -- it threw away the segment that
                 * distinguishes this hit from the other eight called `Enabled`
                 * and kept the one they all share, which is the wrong half of
                 * a path to keep and exactly the bug the header breadcrumb was
                 * already fixed for. */
                int32_t room = (int32_t)((ctlX - rowX - 8.0f) / AOWL_OV_CW);
                int32_t used = (int32_t)strlen(si->label);
                int32_t have = room - used - 2;
                if (have > 8) {
                    char w[176];
                    int32_t wn = 0, q;
                    for (q = 0; si->path[q] && wn < (int32_t)sizeof(w) - 4; q++) {
                        if (si->path[q] == (char)0x2F) {
                            w[wn++] = OV_SP; w[wn++] = (char)0x3E; w[wn++] = OV_SP;
                        } else w[wn++] = si->path[q];
                    }
                    w[wn] = 0;
                    if (wn > have) {
                        char* from = w + wn - (have - 3);
                        char* sep = strstr(from, "> ");
                        if (sep) from = sep + 2;
                        memmove(w + 3, from, strlen(from) + 1);
                        w[0] = OV_DOT; w[1] = OV_DOT; w[2] = OV_SP;
                    }
                    aowl_ov_textn(rowX + (float)(used + 2) * AOWL_OV_CW, cyy,
                                  w, AOWL_OV_FAINT, have);
                }
            }
            ry += (float)AOWL_OV_ROW_H;
        }
        }
    controls_done: ;
    }

    /* --- the detail strip: the selected control, explained --------------- */
    {
        float dy = y + bodyH - (float)AOWL_OV_SDETAIL_H;
        aowl_ov_rect(rx - 2.0f, dy, rw, (float)AOWL_OV_SDETAIL_H, AOWL_OV_PANEBG);
        aowl_ov_rect(rx - 2.0f, dy, rw, 1.0f, AOWL_OV_EDGE);
        dy += 4.0f;
        if (g_ov.selItem < g_ov.sItemCount) {
            AowlOvSItem* si = &g_ov.sItems[g_ov.selItem];
            char line[256];
            /* The key, then WHERE THE ROW LIVES, as the same `>` breadcrumb
             * the header uses -- not the raw `category` field, which on a deep
             * page is half the path with slashes in it and reads as a
             * different notation for the same thing. One vocabulary for
             * hierarchy across the whole screen. */
            {
                char where[160];
                int32_t wn = 0, q;
                for (q = 0; si->path[q] && wn < (int32_t)sizeof(where) - 4; q++) {
                    if (si->path[q] == (char)0x2F) {
                        where[wn++] = OV_SP; where[wn++] = (char)0x3E;
                        where[wn++] = OV_SP;
                    } else where[wn++] = si->path[q];
                }
                where[wn] = 0;
                aowl_ov_fmt(line, (int32_t)sizeof(line), "%s", si->key);
                aowl_ov_text(rx, dy, line, AOWL_OV_ACCENT);
                if (where[0])
                    aowl_ov_textn(rx + (float)(strlen(si->key) + 3) * AOWL_OV_CW,
                                  dy, where, AOWL_OV_DIM,
                                  rcols - (int32_t)strlen(si->key) - 3);
            }
            dy += (float)AOWL_OV_LINE_H;
            if (!si->implemented) {
                aowl_ov_fmt(line, (int32_t)sizeof(line), "NOT IMPLEMENTED YET -- %s",
                            si->desc[0] ? si->desc
                                        : "read but not acted on in aowlspt yet");
                aowl_ov_wrap(rx, dy, line, AOWL_OV_WARN, rcols, 2);
            } else if (si->desc[0]) {
                aowl_ov_wrap(rx, dy, si->desc, AOWL_OV_DIM, rcols, 2);
            } else {
                aowl_ov_text(rx, dy, "editable; changes are saved to config.json",
                             AOWL_OV_DIM);
            }
        }
    }
}

/* Refreshed on a timer rather than per frame -- see above. */
/* ================================================================== *
 * The logs screen -- filtering and drawing
 *
 * Render thread only. It reads the ring under `cs`, and it holds `cs` for
 * exactly two bounded stretches: the refilter (which runs only when something
 * it depends on has moved) and the copy of the <= `rows` lines about to be
 * drawn. It never draws with the lock held and it never does file IO.
 * ================================================================== */

static const char* aowl_ov_log_src_name(int32_t f) {
    if (f == AOWL_LOGSRC_SERVER) return "server";
    if (f == AOWL_LOGSRC_CLIENT) return "client";
    return "all";
}

/* The level filter. `warn+` is the one people actually reach for, so it is the
 * first step off `all`; the exact-level states follow it. */
enum { AOWL_LOGF_ALL = 0, AOWL_LOGF_WARNPLUS, AOWL_LOGF_ERROR, AOWL_LOGF_WARN,
       AOWL_LOGF_INFO, AOWL_LOGF_OK, AOWL_LOGF_UNKNOWN, AOWL_LOGF_COUNT };

static const char* aowl_ov_log_lvlf_name(int32_t f) {
    if (f == AOWL_LOGF_WARNPLUS) return "warn+";
    if (f == AOWL_LOGF_ERROR) return "error";
    if (f == AOWL_LOGF_WARN) return "warn";
    if (f == AOWL_LOGF_INFO) return "info";
    if (f == AOWL_LOGF_OK) return "ok";
    if (f == AOWL_LOGF_UNKNOWN) return "unparsed";
    return "all";
}

static const char* aowl_ov_log_facet_name(int32_t f) {
    if (f == AOWL_LOG_FACET_ALL) return "all";
    if (f == AOWL_LOG_FACET_SYSTEM) return "system";
    if (f >= 0 && f < g_ov.logFacetN) return g_ov.logFacets[f];
    return "all";
}

/* Case-insensitive substring, over the WHOLE line -- elapsed, level and
 * message. Searching only the message would make `warn` un-findable by typing
 * it, which is the sort of surprise the scope line below exists to prevent. */
static int32_t aowl_ov_log_hit(const AowlOvLogLine* L, const char* term) {
    if (!term[0]) return 1;
    return aowl_ov_ci_find(L->text, term);
}

/* THE ONE PREDICATE. Every filter goes through here and nothing else decides
 * what is on screen, so "no combination of filters can display a line whose
 * source, level or facet does not match" is a property of four `if`s rather
 * than of a drawing loop nobody can audit. */
static int32_t aowl_ov_log_pass(const AowlOvLogLine* L) {
    if (g_ov.logSrcFilt == AOWL_LOGSRC_SERVER && L->src != AOWL_LOG_SERVER)
        return 0;
    if (g_ov.logSrcFilt == AOWL_LOGSRC_CLIENT && L->src != AOWL_LOG_CLIENT)
        return 0;
    switch (g_ov.logLvlFilt) {
        case AOWL_LOGF_ALL: break;
        case AOWL_LOGF_WARNPLUS:
            if (L->lvl != AOWL_LOGLVL_WARN && L->lvl != AOWL_LOGLVL_ERR)
                return 0;
            break;
        case AOWL_LOGF_ERROR:   if (L->lvl != AOWL_LOGLVL_ERR) return 0; break;
        case AOWL_LOGF_WARN:    if (L->lvl != AOWL_LOGLVL_WARN) return 0; break;
        case AOWL_LOGF_INFO:    if (L->lvl != AOWL_LOGLVL_INFO) return 0; break;
        case AOWL_LOGF_OK:      if (L->lvl != AOWL_LOGLVL_OK) return 0; break;
        case AOWL_LOGF_UNKNOWN:
            if (L->lvl != AOWL_LOGLVL_UNKNOWN) return 0;
            break;
        default: break;
    }
    if (g_ov.logFacetFilt != AOWL_LOG_FACET_ALL &&
        L->facet != g_ov.logFacetFilt) return 0;
    return aowl_ov_log_hit(L, g_ov.logSearch);
}

/* What `logFilt` was computed for. Any change in any of these re-derives it;
 * nothing else does, so a still frame with the screen open walks zero lines. */
static uint32_t aowl_ov_log_stamp(void) {
    uint32_t h = 2166136261u;
    int32_t k;
    aowl_ov_sig_add(&h, g_ov.logSerial);
    aowl_ov_sig_add(&h, g_ov.logSrcFilt);
    aowl_ov_sig_add(&h, g_ov.logLvlFilt);
    aowl_ov_sig_add(&h, g_ov.logFacetFilt);
    for (k = 0; g_ov.logSearch[k]; k++) aowl_ov_sig_add(&h, g_ov.logSearch[k]);
    return h ? h : 1u;
}

static void aowl_ov_log_refilter(void) {
    uint32_t want = aowl_ov_log_stamp();
    int32_t first, seq, n = 0;
    if (want == g_ov.logFiltStamp) return;
    EnterCriticalSection(&g_ov.cs);
    first = g_ov.logSeq - g_ov.logCount;
    if (first < 0) first = 0;
    for (seq = first; seq < g_ov.logSeq && n < AOWL_OV_LOG_MAX; seq++)
        if (aowl_ov_log_pass(&g_ov.logs[seq % AOWL_OV_LOG_MAX]))
            g_ov.logFilt[n++] = seq;
    LeaveCriticalSection(&g_ov.cs);
    g_ov.logFiltN = n;
    g_ov.logFiltStamp = want;
    if (g_ov.sel[AOWL_VIEW_LOGS] >= n) g_ov.sel[AOWL_VIEW_LOGS] = n > 0 ? n - 1 : 0;
    /* Following means the newest line, not the newest line that used to pass:
     * changing a filter with follow on lands on the last MATCH. */
    if (g_ov.logFollow) g_ov.sel[AOWL_VIEW_LOGS] = n > 0 ? n - 1 : 0;
}

static int32_t aowl_ov_log_searching(void) { return g_ov.logSearchFocus; }

/* The facet cycle: all -> system -> each facet in the order it was first seen
 * -> back to all. `dir` is +1 or -1. */
static void aowl_ov_log_cycle_facet(int32_t dir) {
    int32_t f = g_ov.logFacetFilt;
    int32_t lo = AOWL_LOG_FACET_ALL, hi = g_ov.logFacetN - 1;
    f += dir;
    if (f > hi) f = lo;
    if (f < lo) f = hi < lo ? lo : hi;
    g_ov.logFacetFilt = f;
}

/* Keys, when the LOGS view has them. Called from `aowl_ov_keys`, after the
 * window keys (F9/F10/F11) and before the manager`s own list keys, so nothing
 * here can shadow a key that works everywhere.
 *
 * THE SEARCH FIELD DOES NOT STEAL FOCUS. It is drawn on every frame of this
 * screen and it owns the keyboard only after `/` or a click on it, which is
 * the rule the settings screen already follows and the one that was broken and
 * fixed earlier today. `-` and `=` therefore keep working here in exactly the
 * state the screen opens in.
 *
 * Returns 1 when it consumed the key. */
static int32_t aowl_ov_logs_key(LONG vk, int32_t page, int32_t count) {
    int32_t L;
    char ch;
    if (g_ov.logSearchFocus) {
        if (vk == VK_ESCAPE) { g_ov.logSearch[0] = 0; g_ov.logSearchFocus = 0; return 1; }
        if (vk == VK_RETURN || vk == VK_DOWN || vk == VK_TAB) {
            g_ov.logSearchFocus = 0; return 1;
        }
        if (vk == VK_BACK) {
            L = (int32_t)strlen(g_ov.logSearch);
            if (L > 0) g_ov.logSearch[L - 1] = 0;
            return 1;
        }
        ch = aowl_ov_vk_char(vk);
        if (ch) {
            if (ch >= 0x41 && ch <= 0x5A) ch = (char)(ch + 32);
            L = (int32_t)strlen(g_ov.logSearch);
            if (L < (int32_t)sizeof(g_ov.logSearch) - 1) {
                g_ov.logSearch[L] = ch; g_ov.logSearch[L + 1] = 0;
            }
        }
        return 1;   /* a focused field consumes EVERY printable key */
    }
    if (vk == VK_OEM_2) { g_ov.logSearchFocus = 1; return 1; }
    /* The four filters. Letters that the manager views do not already use --
     * `F`, `C`, `A`, `R`, `W` and `S` are taken, and `1`-`5` jump views. */
    if (vk == 'O') {
        g_ov.logSrcFilt = (g_ov.logSrcFilt + 1) % AOWL_LOGSRC_COUNT;
        return 1;
    }
    if (vk == 'L') {
        g_ov.logLvlFilt = (g_ov.logLvlFilt + 1) % AOWL_LOGF_COUNT;
        return 1;
    }
    if (vk == 'M') { aowl_ov_log_cycle_facet(+1); return 1; }
    if (vk == 'N') { aowl_ov_log_cycle_facet(-1); return 1; }
    if (vk == 'G') { g_ov.logFollow = !g_ov.logFollow; return 1; }
    /* Moving off the bottom by hand is how you stop following; END resumes. */
    if (vk == VK_UP || vk == VK_PRIOR || vk == VK_HOME || vk == 'W')
        g_ov.logFollow = 0;
    if (vk == VK_END) g_ov.logFollow = 1;
    (void)page; (void)count;
    return 0;
}

/* The body. `rows` is how many log lines fit under the two-line filter strip
 * and above the three-line detail pane. */
static void aowl_ov_view_logs(float x, float y, float w, float bodyH,
                              int32_t rows) {
    int32_t cols = (int32_t)(w / AOWL_OV_CW);
    int32_t sel, i, held, dropped, seqLo;
    float ry, sy = y;
    char line[288];
    /* The visible page, copied out from under the lock in one go. 40 lines of
     * 208 bytes is 8 KB of stack, which is why `rows` is clamped: a panel
     * maximised on a 4K screen is about 34 rows at scale 3. */
    AowlOvLogLine page[64];
    int32_t pageN = 0, top;

    aowl_ov_log_refilter();
    sel = g_ov.sel[AOWL_VIEW_LOGS];

    /* --- the filter strip, one line, every chip clickable ---------------- */
    {
        float cx = x + AOWL_OV_PAD;
        struct { const char* k; const char* lab; const char* val; int32_t on; } chip[4];
        int32_t c;
        chip[0].k = "O"; chip[0].lab = "source";
        chip[0].val = aowl_ov_log_src_name(g_ov.logSrcFilt);
        chip[0].on = g_ov.logSrcFilt != AOWL_LOGSRC_ALL;
        chip[1].k = "L"; chip[1].lab = "level";
        chip[1].val = aowl_ov_log_lvlf_name(g_ov.logLvlFilt);
        chip[1].on = g_ov.logLvlFilt != AOWL_LOGF_ALL;
        chip[2].k = "M"; chip[2].lab = "mod";
        chip[2].val = aowl_ov_log_facet_name(g_ov.logFacetFilt);
        chip[2].on = g_ov.logFacetFilt != AOWL_LOG_FACET_ALL;
        chip[3].k = "G"; chip[3].lab = "follow";
        chip[3].val = g_ov.logFollow ? "on" : "off";
        chip[3].on = g_ov.logFollow;
        for (c = 0; c < 4; c++) {
            float cw;
            int32_t hot;
            aowl_ov_fmt(line, (int32_t)sizeof(line), " %s %s: %s ",
                        chip[c].k, chip[c].lab, chip[c].val);
            cw = (float)(strlen(line) * AOWL_OV_CW);
            if (cx + cw > x + w) break;   /* never draw past the pane */
            hot = aowl_ov_hit(cx, sy, cw, (float)AOWL_OV_ROW_H);
            aowl_ov_rect(cx, sy, cw, (float)AOWL_OV_ROW_H,
                         chip[c].on ? AOWL_OV_SELBG
                                    : (hot ? AOWL_OV_HOT : AOWL_OV_PANEBG));
            aowl_ov_text(cx, sy + 3.0f, line,
                         chip[c].on ? AOWL_OV_ACCENT : AOWL_OV_DIM);
            if (hot && g_ov.clickDown) {
                if (c == 0) g_ov.logSrcFilt = (g_ov.logSrcFilt + 1) % AOWL_LOGSRC_COUNT;
                else if (c == 1) g_ov.logLvlFilt = (g_ov.logLvlFilt + 1) % AOWL_LOGF_COUNT;
                else if (c == 2) aowl_ov_log_cycle_facet(+1);
                else g_ov.logFollow = !g_ov.logFollow;
                InterlockedExchange(&g_ov.clickDown, 0);
                aowl_ov_log_refilter();
                sel = g_ov.sel[AOWL_VIEW_LOGS];
            }
            cx += cw + 6.0f;
        }
        sy += (float)AOWL_OV_ROW_H + 2.0f;
    }

    /* --- the search box, same shape and same focus rule as the settings
     * screen`s: always visible, focused only by `/` or a click. -------- */
    {
        float bh = (float)AOWL_OV_SEARCH_BOX;
        float bx = x + AOWL_OV_PAD, bw = w - 2.0f * AOWL_OV_PAD;
        int32_t hot = aowl_ov_hit(bx, sy, bw, bh);
        int32_t on = g_ov.logSearchFocus;
        aowl_ov_rect(bx, sy, bw, bh,
                     on ? AOWL_OV_SELBG : (hot ? AOWL_OV_HOT : AOWL_OV_PANEBG));
        aowl_ov_frame_rect(bx, sy, bw, bh, on ? 2.0f : 1.0f,
                           on ? AOWL_OV_ACCENT : AOWL_OV_EDGE);
        aowl_ov_text(bx + 6.0f, sy + 3.0f, "[/]",
                     on ? AOWL_OV_ACCENT : AOWL_OV_DIM);
        if (g_ov.logSearch[0])
            aowl_ov_fmt(line, (int32_t)sizeof(line), "%s%s", g_ov.logSearch,
                        on ? "_" : "");
        else
            aowl_ov_fmt(line, (int32_t)sizeof(line), "%s",
                        on ? "_" : "search both logs -- time, level and message");
        aowl_ov_textn(bx + 6.0f + 4.0f * AOWL_OV_CW, sy + 3.0f, line,
                      g_ov.logSearch[0] ? AOWL_OV_TEXT : AOWL_OV_FAINT,
                      (int32_t)((bw - 12.0f - 4.0f * AOWL_OV_CW) / AOWL_OV_CW));
        if (g_ov.logSearch[0]) {
            float cxx = bx + bw - 4.0f * AOWL_OV_CW;
            int32_t hotC = aowl_ov_hit(cxx - 2.0f, sy, 3.0f * AOWL_OV_CW, bh);
            aowl_ov_text(cxx, sy + 3.0f, "[x]", hotC ? AOWL_OV_TEXT : AOWL_OV_DIM);
            if (hotC && g_ov.clickDown) {
                g_ov.logSearch[0] = 0; g_ov.logSearchFocus = 0;
                InterlockedExchange(&g_ov.clickDown, 0);
                hot = 0;
            }
        }
        if (hot && g_ov.clickDown) {
            g_ov.logSearchFocus = 1;
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        sy += bh + 3.0f;
    }

    /* --- what was searched, and what is being held --------------------- */
    EnterCriticalSection(&g_ov.cs);
    held = g_ov.logCount;
    dropped = g_ov.logDropped;
    seqLo = g_ov.logSeq - g_ov.logCount;
    LeaveCriticalSection(&g_ov.cs);
    aowl_ov_fmt(line, (int32_t)sizeof(line),
                "%d of %d lines held (%d server, %d client)%s%s",
                g_ov.logFiltN, held,
                g_ov.logLines[AOWL_LOG_SERVER], g_ov.logLines[AOWL_LOG_CLIENT],
                dropped > 0 ? "  older lines dropped: " : "",
                dropped > 0 ? "yes" : "");
    if (dropped > 0)
        aowl_ov_fmt(line, (int32_t)sizeof(line),
                    "%d of %d lines held  (%d server, %d client)  %d older "
                    "lines scrolled out of the ring",
                    g_ov.logFiltN, held, g_ov.logLines[AOWL_LOG_SERVER],
                    g_ov.logLines[AOWL_LOG_CLIENT], dropped);
    aowl_ov_textn(x + AOWL_OV_PAD, sy, line, AOWL_OV_FAINT, cols);
    sy += (float)AOWL_OV_LINE_H;

    /* A source that is switched off, or that has never produced a line, says
     * so IN WORDS. An empty pane that does not distinguish "the file is not
     * there" from "the log is quiet" is the silent decline this project keeps
     * paying for. */
    for (i = 0; i < AOWL_LOG_SRCS; i++) {
        if (!g_ov.logWhy[i][0]) continue;
        aowl_ov_fmt(line, (int32_t)sizeof(line), "%s log: %s",
                    i == AOWL_LOG_SERVER ? "server" : "client", g_ov.logWhy[i]);
        aowl_ov_textn(x + AOWL_OV_PAD, sy, line,
                      g_ov.logOff2[i] ? AOWL_OV_ERR : AOWL_OV_WARN, cols);
        sy += (float)AOWL_OV_LINE_H;
    }

    /* --- rows ---------------------------------------------------------- */
    rows = (int32_t)((y + bodyH - 3.0f * AOWL_OV_LINE_H - sy) / AOWL_OV_ROW_H);
    if (rows < 1) rows = 1;
    if (rows > (int32_t)(sizeof(page) / sizeof(page[0])))
        rows = (int32_t)(sizeof(page) / sizeof(page[0]));

    if (g_ov.logFiltN == 0) {
        aowl_ov_wrap(x + AOWL_OV_PAD, sy,
                     held == 0
                       ? "Nothing has been read from either log yet. The two "
                         "files are read directly from the install directory, "
                         "so this screen works with the backend down."
                       : "No line matches. O cycles the source, L the level, "
                         "M the mod, and / searches -- ESC in the box clears "
                         "the term.",
                     AOWL_OV_DIM, cols - 3, 4);
        return;
    }

    top = g_ov.top[AOWL_VIEW_LOGS];
    if (top > sel) top = sel;
    if (sel - top >= rows) top = sel - rows + 1;
    if (top > g_ov.logFiltN - rows) top = g_ov.logFiltN - rows;
    if (top < 0) top = 0;
    g_ov.top[AOWL_VIEW_LOGS] = top;

    EnterCriticalSection(&g_ov.cs);
    for (i = 0; i < rows && top + i < g_ov.logFiltN; i++) {
        int32_t seq = g_ov.logFilt[top + i];
        /* Evicted since the filter was built. Cannot happen while `logSerial`
         * drives the stamp -- every append bumps it -- but a row drawn from a
         * slot that has been overwritten is exactly the kind of plausible-
         * looking wrong answer this file keeps a rule about, so it is checked
         * rather than assumed. */
        if (seq < seqLo || seq >= g_ov.logSeq) {
            page[pageN].text[0] = 0;
            page[pageN].src = -1;
            page[pageN].lvl = AOWL_LOGLVL_UNKNOWN;
            page[pageN].facet = AOWL_LOG_FACET_SYSTEM;
            page[pageN].msgAt = 0;
        } else {
            page[pageN] = g_ov.logs[seq % AOWL_OV_LOG_MAX];
        }
        pageN++;
    }
    LeaveCriticalSection(&g_ov.cs);

    ry = sy;
    for (i = 0; i < pageN; i++) {
        AowlOvLogLine* Ln = &page[i];
        uint32_t col = aowl_ov_log_lvl_col(Ln->lvl);
        if (top + i == sel)
            aowl_ov_rect(x + 1.0f, ry, w + AOWL_OV_PAD * 2 - 2.0f,
                         (float)AOWL_OV_ROW_H, AOWL_OV_SELBG);
        if (Ln->src < 0) {
            aowl_ov_textn(x + AOWL_OV_PAD, ry + 3.0f,
                          "(this line scrolled out of the ring while you were "
                          "looking at it)", AOWL_OV_DIM, cols);
            ry += (float)AOWL_OV_ROW_H;
            continue;
        }
        aowl_ov_text(x + AOWL_OV_PAD, ry + 3.0f,
                     Ln->src == AOWL_LOG_SERVER ? "srv" : "cli",
                     Ln->src == AOWL_LOG_SERVER ? AOWL_OV_ACCENT : AOWL_OV_DIM);
        aowl_ov_textn(x + AOWL_OV_PAD + 4.0f * AOWL_OV_CW, ry + 3.0f,
                      Ln->text, col, cols - 5);
        ry += (float)AOWL_OV_ROW_H;
    }

    /* The selected line in full, wrapped: a log line is longer than the pane
     * and a screen that can only show its first sixty characters is a screen
     * that cannot answer the question it was opened for. */
    if (sel >= 0 && sel < g_ov.logFiltN && sel - top >= 0 && sel - top < pageN) {
        AowlOvLogLine* Ln = &page[sel - top];
        float dy = y + bodyH - 3.0f * (float)AOWL_OV_LINE_H;
        aowl_ov_rect(x + 1.0f, dy - 4.0f, w + AOWL_OV_PAD * 2 - 2.0f, 1.0f,
                     AOWL_OV_EDGE);
        if (Ln->src >= 0) {
            aowl_ov_fmt(line, (int32_t)sizeof(line), "%s  %s  %s",
                        Ln->src == AOWL_LOG_SERVER ? "server" : "client",
                        aowl_ov_log_lvl_name(Ln->lvl),
                        Ln->facet == AOWL_LOG_FACET_SYSTEM
                          ? "system" : aowl_ov_log_facet_name(Ln->facet));
            aowl_ov_textn(x + AOWL_OV_PAD, dy, line,
                          aowl_ov_log_lvl_col(Ln->lvl), cols);
            aowl_ov_wrap(x + AOWL_OV_PAD, dy + (float)AOWL_OV_LINE_H,
                         Ln->text, AOWL_OV_TEXT, cols - 3, 2);
        }
    }
}

static void aowl_ov_refresh_display(void) {
    DWORD now = GetTickCount();
    if (g_ov.dispTick != 0 && now - g_ov.dispTick < 500) return;
    g_ov.dispTick = now ? now : 1;
    g_ov.dispAvgNs = (int32_t)g_ov.avgNs;
    g_ov.dispMaxNs = (int32_t)g_ov.maxNs;
    g_ov.dispRttMs = (int32_t)g_ov.lastRttMs;
    g_ov.dispStaleS = g_ov.everOk
        ? (int32_t)((now - (DWORD)g_ov.lastOkTick) / 1000) : 0;
}

static void aowl_ov_sig_add(uint32_t* h, int32_t v) {
    /* FNV-1a over the four bytes. Any mixing function would do; this one is
     * four lines and has no table. */
    uint32_t i;
    for (i = 0; i < 4; i++) {
        *h ^= (uint32_t)((v >> (i * 8)) & 0xFF);
        *h *= 16777619u;
    }
}

/* Everything that changes what is on screen, and nothing that does not.
 *
 * `dataSerial` stands in for the whole of the mod, list, issue and result
 * tables: the worker bumps it whenever it has changed one of them, which is the
 * same signal the snapshot already uses. Adding the tables themselves here
 * would mean hashing 60 KB a frame to avoid rebuilding 7,000 vertices. */
static uint32_t aowl_ov_signature(void) {
    uint32_t h = 2166136261u;
    int32_t i;
    aowl_ov_sig_add(&h, g_ov.dataSerial);
    aowl_ov_sig_add(&h, g_ov.view);
    aowl_ov_sig_add(&h, g_ov.filter);
    for (i = 0; i < AOWL_VIEW_COUNT; i++) {
        aowl_ov_sig_add(&h, g_ov.sel[i]);
        aowl_ov_sig_add(&h, g_ov.top[i]);
    }
    aowl_ov_sig_add(&h, (int32_t)g_ov.mx);
    aowl_ov_sig_add(&h, (int32_t)g_ov.my);
    aowl_ov_sig_add(&h, (int32_t)g_ov.bbW);
    aowl_ov_sig_add(&h, (int32_t)g_ov.bbH);
    aowl_ov_sig_add(&h, g_ov.scale);
    aowl_ov_sig_add(&h, (int32_t)g_ov.backendOk);
    aowl_ov_sig_add(&h, (int32_t)g_ov.everOk);
    aowl_ov_sig_add(&h, (int32_t)g_ov.busy);
    aowl_ov_sig_add(&h, g_ov.backendPort);
    aowl_ov_sig_add(&h, g_ov.dispAvgNs);
    aowl_ov_sig_add(&h, g_ov.dispMaxNs);
    /* A flag, not a count: the title bar says `was` while the cost is still
     * the previous opening's, and without this the frame that stops being true
     * can land on a cache hit and leave the word up. */
    aowl_ov_sig_add(&h, g_ov.openDrawn < AOWL_OV_COST_SETTLE ? 1 : 0);
    aowl_ov_sig_add(&h, g_ov.dispRttMs);
    aowl_ov_sig_add(&h, g_ov.dispStaleS);
    /* The settings screen's own cursor and edit state, so a change on it -- a
     * page picked, a row selected, a slider dragged, a text box opened -- forces
     * the same rebuild the manager views get. `mouseHeld` is here rather than in
     * the manager set because only a slider reads it every frame. */
    aowl_ov_sig_add(&h, g_ov.settings);
    aowl_ov_sig_add(&h, g_ov.selPage);
    aowl_ov_sig_add(&h, g_ov.topPage);
    aowl_ov_sig_add(&h, g_ov.selItem);
    aowl_ov_sig_add(&h, g_ov.topItem);
    aowl_ov_sig_add(&h, g_ov.editItem);
    aowl_ov_sig_add(&h, g_ov.capturing);
    aowl_ov_sig_add(&h, g_ov.dragItem);
    aowl_ov_sig_add(&h, (int32_t)g_ov.mouseHeld);
    aowl_ov_sig_add(&h, (int32_t)(g_ov.dragVal * 1000.0f));
    /* The in-progress text, so a keystroke that only changes the edit buffer
     * still rebuilds the frame it lands on. */
    {
        int32_t k;
        for (k = 0; g_ov.editBuf[k]; k++) aowl_ov_sig_add(&h, g_ov.editBuf[k]);
    }
    /* The second-level nav cursor. It was missing: picking a sub-tab with the
     * mouse changed `selItem` too and so happened to rebuild, but `,`/`.` back
     * out to "the whole page" without moving `selItem` at all, and that frame
     * could land on a cache hit and leave the previous sub-tab on screen. */
    aowl_ov_sig_add(&h, g_ov.selCat);
    /* Which side has the keyboard, and whether either list is free-scrolled.
     * Both change what is DRAWN -- the focus fill on the selected rows, and
     * `topItem` -- without necessarily moving a cursor, so a frame that
     * changed only one of them would otherwise land on a cache hit. */
    aowl_ov_sig_add(&h, g_ov.navFocus);
    aowl_ov_sig_add(&h, g_ov.itemFree);
    /* The search box: the term, whether it has the keyboard, and what it
     * matched. */
    {
        int32_t k;
        for (k = 0; g_ov.search[k]; k++) aowl_ov_sig_add(&h, g_ov.search[k]);
    }
    aowl_ov_sig_add(&h, g_ov.searchFocus);
    /* F8 changes the legend and the empty-page sentence directly, not only
     * through `dataSerial` -- a cache keyed on the data alone would keep
     * drawing "F8 show" after F8 had already shown them. */
    aowl_ov_sig_add(&h, g_ov.showUnimpl);
    aowl_ov_sig_add(&h, g_ov.sHiddenCount);
    /* The nav`s expansion. Collapsing a branch moves no cursor, so without
     * these the frame that closed it could land on a cache hit and leave the
     * branch on screen -- a tree that ignores the first click on its own
     * disclosure marker. */
    {
        int32_t k;
        for (k = 0; k < g_ov.sCatCount && k < AOWL_OV_MAX_SCATS; k++)
            aowl_ov_sig_add(&h, g_ov.navOpen[k]);
        for (k = 0; k < g_ov.sPageCount && k < AOWL_OV_MAX_SPAGES; k++)
            aowl_ov_sig_add(&h, g_ov.pageOpen[k]);
    }
    aowl_ov_sig_add(&h, g_ov.filtCount);
    /* The logs screen. `logSerial` covers the ring; the rest is the filter
     * state, which changes what is drawn without moving any cursor -- exactly
     * the case that leaves a stale frame on screen when it is left out. */
    aowl_ov_sig_add(&h, g_ov.logSerial);
    aowl_ov_sig_add(&h, g_ov.logSrcFilt);
    aowl_ov_sig_add(&h, g_ov.logLvlFilt);
    aowl_ov_sig_add(&h, g_ov.logFacetFilt);
    aowl_ov_sig_add(&h, g_ov.logFollow);
    aowl_ov_sig_add(&h, g_ov.logSearchFocus);
    aowl_ov_sig_add(&h, g_ov.logFiltN);
    aowl_ov_sig_add(&h, g_ov.logFacetN);
    {
        int32_t k;
        for (k = 0; g_ov.logSearch[k]; k++) aowl_ov_sig_add(&h, g_ov.logSearch[k]);
    }
    /* The window. A drag moves the panel without touching any cursor, so
     * without these a dragged panel would stop redrawing at its old position. */
    aowl_ov_sig_add(&h, (int32_t)(g_ov.panX * 4.0f));
    aowl_ov_sig_add(&h, (int32_t)(g_ov.panY * 4.0f));
    aowl_ov_sig_add(&h, (int32_t)(g_ov.panW * 4.0f));
    aowl_ov_sig_add(&h, (int32_t)(g_ov.panH * 4.0f));
    aowl_ov_sig_add(&h, g_ov.panMax);
    /* The panel's own preferences are part of what is on screen, so a change to
     * any of them has to invalidate the "nothing moved, do not redraw" cache.
     * Leaving them out is how a theme switch produces a frame that is still the
     * old theme -- and then stays that way until something unrelated moves. */
    aowl_ov_sig_add(&h, g_ov.showFooter);
    aowl_ov_sig_add(&h, g_ov.navW);
    aowl_ov_sig_add(&h, g_ov.panAlpha);
    aowl_ov_sig_add(&h, g_ov.scalePref);
    aowl_ov_sig_add(&h, (int32_t)g_ovTheme.bg);
    aowl_ov_sig_add(&h, (int32_t)g_ovTheme.accent);
    aowl_ov_sig_add(&h, g_ov.topPage);
    aowl_ov_sig_add(&h, g_ov.panAlpha);
    aowl_ov_sig_add(&h, g_ov.dragWin);
    aowl_ov_sig_add(&h, g_ov.dragGrip);
    /* Never zero: zero is what `aowl_ov_bind` writes to force the next frame to
     * rebuild after a device change. */
    return h ? h : 1u;
}

/* Builds the frame's geometry and consumes at most one click. Returns nothing;
 * everything it decides is either geometry or a queued command. */
static void aowl_ov_build(void) {
    float x, y, w, h, bodyY, bodyH, innerW, legendH;
    float availW, availH, mxp, myp;
    int32_t vis[AOWL_OV_MAX_MODS];
    int32_t visN, rows, counts[AOWL_VIEW_COUNT];
    char buf[256];
    /* The legend, built before the body so that its height is known, drawn
     * after it. `legNote` is the marker legend or, when something went wrong,
     * what went wrong -- they share the line and so they share the buffer. */
    char legKeys[288], legNote[256];
    int32_t legCols = 0, legKeyN = 1, legNoteN = 1;
    float titleRight = 0.0f;   /* where the window controls start */
    uint32_t healthCol;
    /* THE PALETTE MUST EXIST BEFORE THE FIRST RECTANGLE.
     *
     * `aowl_ov_start` loads the themes, but this file is also included by test
     * hosts and probes that draw without going through it -- and a zeroed
     * `g_ovTheme` is not a wrong colour, it is transparent black on
     * transparent black, i.e. a panel that renders as nothing at all. One
     * integer compare a frame buys the guarantee that cannot happen. */
    if (g_ovThemeCount == 0) aowl_ov_themes_load();
    healthCol = AOWL_OV_DIM;

    aowl_ov_snapshot();
    aowl_ov_refresh_display();

    /* WHETHER THE WORKER SHOULD BE TAILING THE LOGS AT ALL. Set before the
     * geometry cache's early return, not inside the view function: the view
     * function does not run on a cached frame, and a flag that only gets set
     * when the panel happens to be rebuilding is a flag that switches itself
     * off the moment the screen goes still -- which is precisely when somebody
     * is reading it. */
    InterlockedExchange(&g_ov.logWant,
                        (!g_ov.settings && g_ov.view == AOWL_VIEW_LOGS) ? 1 : 0);

    /* Nothing moved and nothing is waiting: last frame's vertices are still on
     * the GPU and still correct. Checking input first, because `aowl_ov_keys`
     * runs inside this function and a skipped frame must never eat a keypress. */
    {
        int32_t input = (g_ov.keyHead != g_ov.keyTail) || g_ov.clickDown ||
                        g_ov.wheel;
        if (!input && g_ov.vtxCount > 0 &&
            aowl_ov_signature() == g_ov.drawSig)
            return;
    }
    g_ov.builds++;
    g_ov.vtxCount = 0;
    g_ov.spanN = 0;

    /* The scale first, because everything below is in panel units and the
     * available room is the back buffer divided by it.
     *
     * An 8x16 font on a 3,840x2,160 back buffer is a 940-pixel panel of
     * two-millimetre text in the corner of a 32-inch monitor: legible in a
     * screenshot, useless in a raid. So the whole panel is drawn at an integer
     * factor, chosen from the back buffer's height because that is what runs
     * out first. 3x is reserved for something taller than 4K -- at 2x a 4K
     * panel is already 1,880x1,240, and 3x there would be most of the screen.
     *
     * Hysteresis-free on purpose: the factor is a function of the back buffer
     * and nothing else, so a resize gives the same answer every time and
     * `aowl_ov_bind` invalidating the geometry cache on a size change is all
     * the bookkeeping it needs. */
    g_ov.scale = g_ov.scalePref > 0 ? g_ov.scalePref
               : (g_ov.bbH >= 2500) ? 3 : (g_ov.bbH >= 1300) ? 2 : 1;
    availW = (g_ov.bbW ? (float)g_ov.bbW : 1280.0f) / (float)g_ov.scale;
    availH = (g_ov.bbH ? (float)g_ov.bbH : 720.0f) / (float)g_ov.scale;
    mxp = (float)g_ov.mx / (float)g_ov.scale;
    myp = (float)g_ov.my / (float)g_ov.scale;

    /* --- WHERE THE PANEL IS, AND HOW BIG ---------------------------------
     *
     * It used to be a constant clamped to the back buffer, which is why it
     * could not be moved, resized or maximised. Now it is four numbers of
     * state, loaded from disk at start and written back when a drag ends, and
     * this block is only their clamp. The clamp is the important half: a saved
     * position that no longer fits (the player changed resolution, or unplugged
     * the second monitor) must produce a panel that is ON SCREEN, not a
     * faithful restoration of somewhere unreachable.
     *
     * Maximised is not a different code path -- it is the same four numbers
     * pinned to the client area, so every rectangle below is unchanged and the
     * un-maximise restores what was saved rather than recomputing a default. */
    if (g_ov.panW < 1.0f) aowl_ov_prefs_default();
    if (g_ov.panMax) {
        x = 0.0f; y = 0.0f; w = availW; h = availH;
    } else {
        w = g_ov.panW; h = g_ov.panH; x = g_ov.panX; y = g_ov.panY;
        if (w > availW) w = availW;
        if (w < 480.0f) w = 480.0f;
        if (h > availH) h = availH;
        if (h < 220.0f) h = 220.0f;
        /* Never entirely off: at least the title bar and a hand`s width of it
         * stay inside, so there is always something to grab. */
        if (x > availW - 80.0f) x = availW - 80.0f;
        if (x < -(w - 80.0f)) x = -(w - 80.0f);
        if (y > availH - (float)AOWL_OV_TITLE_H) y = availH - (float)AOWL_OV_TITLE_H;
        if (y < 0.0f) y = 0.0f;
        /* ...and the BOTTOM stays on screen too. This is the clamp the old
         * fixed-position code did with `h > availH - y - 30`, kept because
         * without it a 620-tall panel at y=60 in a 600-tall client area puts
         * its legend below the back buffer -- and a panel whose legend is off
         * the bottom of the screen is a panel with no legend, which is the
         * argument for printing one at all. Measured, not assumed: dropping
         * this is what made `tests/overlayhost`s legend readback fail.
         *
         * The right edge gets the same treatment, but only when the panel has
         * not been dragged off to the LEFT -- there, hanging off is the
         * player`s own doing and shrinking the panel under them would be a
         * window that resizes itself when moved. */
        if (y + h > availH) h = availH - y;
        if (h < 220.0f) h = 220.0f;
        if (x >= 0.0f && x + w > availW) w = availW - x;
        if (w < 480.0f) w = 480.0f;
        /* The POSITION clamp sticks -- a panel dragged off the edge should
         * stay where it was pushed back to. The SIZE clamp does not: it is a
         * function of the back buffer, and writing it back would let one
         * launch in a small window permanently shrink a size the player chose
         * in a big one. */
        g_ov.panX = x; g_ov.panY = y;
    }

    innerW = w - 2.0f * AOWL_OV_PAD;
    bodyY = y + (float)AOWL_OV_HEAD_H;
    bodyH = h - (float)AOWL_OV_HEAD_H - (float)AOWL_OV_LEGEND_H;
    legendH = (float)AOWL_OV_LEGEND_H;

    visN = aowl_ov_visible_rows(vis);
    counts[AOWL_VIEW_MODS] = g_ov.sModCount;
    counts[AOWL_VIEW_LISTS] = g_ov.sListCount;
    counts[AOWL_VIEW_ISSUES] = g_ov.sIssueCount;
    counts[AOWL_VIEW_APPLY] = g_ov.sResultCount;
    /* Cheap: `aowl_ov_log_refilter` returns immediately unless its stamp moved,
     * so this is one hash of a handful of integers on a still frame. It has to
     * run before `aowl_ov_keys`, because PgUp/PgDn and END need the count. */
    if (g_ov.view == AOWL_VIEW_LOGS && !g_ov.settings) aowl_ov_log_refilter();
    counts[AOWL_VIEW_LOGS] = g_ov.logFiltN;

    /* Rows that fit. The mods view gives up the detail pane's height; the
     * others use the whole body. */
    rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H) / AOWL_OV_ROW_H);
    if (g_ov.view == AOWL_VIEW_MODS)
        rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H - (float)AOWL_OV_DETAIL_H)
                         / AOWL_OV_ROW_H);
    if (rows < 1) rows = 1;

    /* Input, before anything is drawn, so a keypress lands on this frame. The
     * wheel scrolls the current view by three rows a notch, which is what every
     * other list on Windows does. In settings mode the page size is the control
     * list's, and the wheel moves the selected control. */
    aowl_ov_keys(g_ov.settings
                     ? aowl_ov_settings_page(bodyH, aowl_ov_settings_rows(bodyH))
                     : rows, vis, visN);
    {
        LONG notches = InterlockedExchange(&g_ov.wheel, 0);
        if (g_ov.settings) {
            /* THE WHEEL BELONGS TO WHICHEVER LIST IS UNDER THE CURSOR.
             *
             * It used to always move the CONTROL list, so the nav could not be
             * scrolled at all -- with more pages than rows, the ones past the
             * bottom were simply unreachable by mouse. The nav's own geometry
             * is not known here, so the notches are handed to
             * `aowl_ov_view_settings`, which owns that geometry, and it decides
             * from the cursor's x, then scrolls whichever list it decided on.
             * Neither branch moves a CURSOR any more: both scroll a view. */
            g_ov.navWheel = (int32_t)notches;
        } else {
            if (notches)
                aowl_ov_move(g_ov.view, -3 * (int32_t)notches,
                             aowl_ov_row_count(g_ov.view, vis, visN));
            /* The filter may have changed under the cursor. */
            visN = aowl_ov_visible_rows(vis);
            counts[AOWL_VIEW_MODS] = g_ov.sModCount;
            if (g_ov.sel[AOWL_VIEW_MODS] >= visN)
                g_ov.sel[AOWL_VIEW_MODS] = visN > 0 ? visN - 1 : 0;
        }
    }

    /* --- how tall the legend has to be, before the body takes the rest ---
     *
     * `AOWL_OV_LEGEND_H` reserves two lines, which is what these two strings
     * take at 115 columns -- the default 940-wide panel -- and not what they
     * take anywhere narrower. The room is `innerW / AOWL_OV_CW`: 115 at the
     * default, 87 at the 800x520 the test host resizes to mid-run, and 57 at
     * the 480 floor `aowl_ov_build` clamps to. The marker legend is 106
     * characters and the mods view's key legend is 95, so at the floor both
     * were being cut in half by `aowl_ov_textn` -- and the whole argument for
     * printing a legend on every view is that the player has not learnt the
     * markers yet. A legend that loses its second half loses exactly the
     * marker nobody knows.
     *
     * So the legend is measured and wrapped rather than clipped, and the body
     * is given what is left. On a wide panel this changes nothing: one line
     * each, `legendH == AOWL_OV_LEGEND_H`, the same layout as before. At the
     * floor it costs the body two rows, which is the right way round -- a row
     * you cannot see is one scroll away, and a marker you cannot see is not.
     *
     * The alternatives were worse in ways worth writing down. Shortening the
     * legend to 57 columns means deleting two of the five markers, which is
     * the same loss with none of the room. Raising the 480 floor to the ~870
     * the untouched legend needs makes the panel wider than the window it is
     * clamped for: the floor exists so a small window gets a usable panel, and
     * a panel hanging off the right edge is not one.
     *
     * Measured here, after the input block, because a TAB or an F in this
     * frame changes which legend this frame prints. `rows` above -- the page
     * size PgUp/PgDn used a moment ago -- was computed from the two-line
     * reservation and is not re-derived: it is one keypress, in the one frame
     * a view changes, and it is followed by a rebuild. */
    {
        int32_t maxN;
        legCols = (int32_t)(innerW / AOWL_OV_CW);
        if (g_ov.settings)
            /* Ordered by how often it is wanted, and phrased so that every
             * item is SHORT -- `aowl_ov_wrap` breaks on spaces, and a legend
             * built from four-word phrases wraps in the middle of one, which
             * is how "F2 mod manager" came to render as "F2 mod" above
             * "manager". Two words each, so a break is always between items. */
            /* Two short lines that describe the input model above, in the
             * order somebody reaches for them -- and every key named here is
             * one that actually works from the state the panel is in when they
             * read it. The old line advertised `-/= opacity` while the search
             * field was quietly eating both. */
            /* THE FOOTER DESCRIBES THE FOCUS THE PANEL IS ACTUALLY IN, and now
             * there are three of them rather than two. A legend that names keys
             * the current focus cannot deliver is the defect that lost `-`/`=`;
             * with a second text field on screen it would be twice as easy to
             * reintroduce, so each state prints only what works from it. */
            if (g_ov.editItem >= 0 && !g_ov.capturing)
                aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                            "TYPING A VALUE   ENTER store   ESC cancel   "
                            "F9 fade   F10 solid   F11 max   F2 manager");
            else if (g_ov.capturing)
                aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                            "PRESS A KEY TO BIND   ESC cancel   "
                            "F9 fade   F10 solid   F11 max   F2 manager");
            else if (g_ov.searchFocus)
                aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                            "TYPING IN SEARCH   ENTER results   ESC cancel   "
                            "F9 fade   F10 solid   F11 max   F2 manager");
            else
                /* Line one is what you DO to a setting; line two is what you
                 * do to the WINDOW. Split that way, and each kept under the
                 * pane width, both fit on one line each at the default size
                 * instead of spilling a third line that begins mid-phrase. */
                /* TAB no longer says "page" -- it moves focus -- and the
                 * legend has to say which side has it, or the arrows silently
                 * mean two different things depending on invisible state. That
                 * is the same failure the `-`/`=` bug was: a key whose effect
                 * depends on a focus the legend does not name. `[`/`]` are
                 * named here now precisely because TAB stopped doing what they
                 * do. Both lines stay inside the pane width at the default
                 * size, which is what `aowl_ov_wrap` is measured against. */
                aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                            g_ov.navFocus
                              ? "NAV   UP/DN move   L/R fold   ENTER settings   "
                                "TAB settings   [ ] page   ESC close"
                              : "/ search   UP/DN row   L/R change   SPACE type   "
                                "TAB nav   [ ] page   ESC close");
        else if (g_ov.view == AOWL_VIEW_MODS)
            aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                        "TAB view  UP/DN move  SPACE toggle  C clear  "
                        "F filter [%s]  A apply  R reload  INS/ESC close",
                        aowl_ov_filter_name(g_ov.filter));
        else if (g_ov.view == AOWL_VIEW_LISTS)
            aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                        "TAB view  UP/DN move  ENTER activate this list  "
                        "A apply  R reload  INS/ESC close");
        else if (g_ov.view == AOWL_VIEW_LOGS)
            /* Named in the order they are reached for, and every key here
             * works from the state the screen OPENS in -- the search box has
             * no focus until `/` or a click, so `-`/`=` are live too. */
            aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                        "/ search   O source   L level   M/N mod   G follow   "
                        "UP/DN line   END newest   TAB view   INS/ESC close");
        else
            aowl_ov_fmt(legKeys, (int32_t)sizeof(legKeys),
                        "TAB view  UP/DN move  1-5 jump  A apply  R reload  "
                        "INS/ESC close");
        /* The second line is the marker legend, *unless* something went wrong
         * -- in which case it is what went wrong, on every view. An error you
         * have to change view to see is an error nobody sees, and the gestures
         * that fail (a refusal from the manager, a backend that is not there)
         * are made from the MODS view where the ISSUES tab is just a number.
         *
         * Which is also why no action here changes the view. Yanking the panel
         * to another pane because a keypress was refused loses the row the
         * player had selected, to tell them something a line of text can. */
        if (g_ov.settings) {
            if (g_ov.editItem >= 0)
                aowl_ov_copy(legNote, (int32_t)sizeof(legNote),
                             "the value box has the keyboard; ESC gives it "
                             "back to the list and keeps the old value");
            else if (g_ov.searchFocus)
                aowl_ov_copy(legNote, (int32_t)sizeof(legNote),
                             "the search field has the keyboard; ESC gives it "
                             "back to the list");
            else if (g_ov.showUnimpl)
                /* State the flag AS READ, on screen, whenever it is on. A
                 * screen full of controls that do nothing, with nothing saying
                 * why, is exactly the confusion the filter exists to remove --
                 * and F8 is a key somebody can hit by accident. */
                aowl_ov_fmt(legNote, (int32_t)sizeof(legNote),
                            "F8 SHOWING %d UNIMPLEMENTED SETTING%s -- NI rows "
                            "are read-only and change nothing.   F2 manager   "
                            "F11 max", g_ov.sHiddenCount,
                            g_ov.sHiddenCount == 1 ? "" : "s");
            else if (g_ov.sHiddenCount > 0)
                aowl_ov_fmt(legNote, (int32_t)sizeof(legNote),
                            "click a number to type it   %d not-yet-"
                            "implemented setting%s hidden (F8)   F2 manager   "
                            "F11 max   F9 fade/F10 solid", g_ov.sHiddenCount,
                            g_ov.sHiddenCount == 1 ? "" : "s");
            else
                aowl_ov_copy(legNote, (int32_t)sizeof(legNote),
                             "click a number to type it   F8 show unimplemented"
                             "   F2 manager   F11 max   F9 fade/F10 solid   "
                             "drag title = move   drag corner = resize");
        }
        else if (g_ov.view == AOWL_VIEW_LOGS && !g_ov.sLastError[0])
            /* The facet rule, ON SCREEN. A filter whose grouping rule is only
             * in a comment is a filter whose empty results look like a bug. */
            aowl_ov_copy(legNote, (int32_t)sizeof(legNote),
                         "read straight from the two log files, so this works "
                         "with the backend down   `mod` groups by a first word "
                         "ending in `:` (sain:, config:); everything else is "
                         "`system`");
        else
            aowl_ov_copy(legNote, (int32_t)sizeof(legNote),
                     g_ov.sLastError[0] ? g_ov.sLastError :
                     "* your override   ~ asked, no answer yet   "
                     "! game disagrees   ON*/OFF* takes a restart   "
                     "dim = not running");
        /* Never past the body's last two rows. A manager refusal is a couple
         * of hundred characters and would otherwise be entitled to eat a short
         * panel whole; past this it wraps to what fits and `aowl_ov_wrap`
         * marks the cut with `..`, which is the one truncation that says so. */
        maxN = (int32_t)((h - (float)AOWL_OV_HEAD_H - (float)(2 * AOWL_OV_ROW_H)
                          - (float)(AOWL_OV_LEGEND_H - 2 * AOWL_OV_LINE_H))
                         / (float)AOWL_OV_LINE_H);
        if (maxN > 2 * AOWL_OV_LEGEND_MAX) maxN = 2 * AOWL_OV_LEGEND_MAX;
        if (maxN < 2) maxN = 2;
        legKeyN = aowl_ov_wrap_lines(legKeys, legCols, AOWL_OV_LEGEND_MAX);
        if (legKeyN > maxN - 1) legKeyN = maxN - 1;
        legNoteN = aowl_ov_wrap_lines(legNote, legCols, AOWL_OV_LEGEND_MAX);
        if (legNoteN > maxN - legKeyN) legNoteN = maxN - legKeyN;
        legendH = (float)(AOWL_OV_LEGEND_H - 2 * AOWL_OV_LINE_H
                          + (legKeyN + legNoteN) * AOWL_OV_LINE_H);
        /* THE FOOTER IS OPTIONAL, and turning it off gives its height to the
         * body rather than leaving a blank strip -- a hidden footer that still
         * costs three rows is not hidden, it is invisible and expensive. The
         * default is ON: the argument above (a keyboard interface whose keys
         * are not on screen is unusable) is still the right default, and this
         * is for the player who has learnt them. */
        if (!g_ov.showFooter) legendH = 0.0f;
        bodyH = h - (float)AOWL_OV_HEAD_H - legendH;
        rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H) / AOWL_OV_ROW_H);
        if (g_ov.view == AOWL_VIEW_MODS)
            rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H
                              - (float)AOWL_OV_DETAIL_H) / AOWL_OV_ROW_H);
        if (rows < 1) rows = 1;
    }

    /* --- chrome --- */
    /* The background, at the opacity the player chose. 255 is the solid
     * background asked for; the old constant`s 232 is the default and is what
     * an install that has never touched the control still gets. Only the alpha
     * moves -- a panel that changed colour as well would stop being the same
     * panel. */
    aowl_ov_rect(x, y, w, h,
                 (AOWL_OV_BG & 0x00FFFFFFu) |
                 ((uint32_t)(g_ov.panAlpha & 0xFF) << 24));
    aowl_ov_rect(x, y, w, (float)AOWL_OV_TITLE_H, AOWL_OV_TITLEBG);
    /* NO BORDER WHEN THERE IS NOTHING TO BE BORDERED FROM.
     *
     * The frame exists to separate a floating window from the game behind it.
     * Maximised, the panel IS the back buffer -- `panMax` pins it to 0,0 and
     * the full `availW`x`availH` a few hundred lines up -- so the frame is a
     * rule around the edge of the screen, which is decoration with no job. It
     * is a property of the STATE, not a setting: nobody should have to turn
     * off a line that only ever appears in a mode where it means nothing.
     *
     * The other floating-case affordances were checked at the same time:
     *   * the RESIZE GRIP was already suppressed under `panMax` (see the
     *     move/resize block below) -- left as it was;
     *   * the TITLE-BAR DRAG was already inert under `panMax` -- but the title
     *     bar itself stays drawn, because it carries the tab strip, the
     *     MANAGER/SETTINGS toggle and the maximise button, which have jobs at
     *     any size;
     *   * there is no drop shadow, no corner rounding and no outer margin in
     *     this renderer to drop -- the panel is axis-aligned rects and the only
     *     inset is `AOWL_OV_PAD`, which is text padding, not window chrome. */
    if (!g_ov.panMax)
        aowl_ov_frame_rect(x, y, w, h, 1.0f, AOWL_OV_EDGE);
    aowl_ov_text(x + AOWL_OV_PAD, y + 5.0f, "aowlspt", AOWL_OV_ACCENT);
    /* The two faces, as a clickable toggle right in the title bar, so the way
     * across is always visible and never a key nobody was told about. F2 does
     * the same from the keyboard. */
    {
        float tx = x + AOWL_OV_PAD + 8.0f * AOWL_OV_CW;
        static const char* modes[2] = { " MANAGER ", " SETTINGS " };
        int32_t m;
        for (m = 0; m < 2; m++) {
            int32_t on = (g_ov.settings == m);
            float tw = (float)(strlen(modes[m]) * AOWL_OV_CW);
            int32_t hot = aowl_ov_hit(tx, y + 2.0f, tw, (float)(AOWL_OV_TITLE_H - 4));
            aowl_ov_rect(tx, y + 2.0f, tw, (float)(AOWL_OV_TITLE_H - 4),
                         on ? AOWL_OV_SELBG : (hot ? AOWL_OV_HOT : AOWL_OV_PANEBG));
            aowl_ov_text(tx, y + 5.0f, modes[m], on ? AOWL_OV_TEXT : AOWL_OV_DIM);
            if (hot && g_ov.clickDown) {
                g_ov.settings = m;
                g_ov.editItem = -1; g_ov.capturing = 0; g_ov.dragItem = -1;
                InterlockedExchange(&g_ov.clickDown, 0);
            }
            tx += tw + 4.0f;
        }
    }
    /* The window controls, at the right end of the title bar: maximise and the
     * opacity readout. Both are also keys (F11, `-`/`=`) and both are printed
     * on the legend, because a control that is only a click is a control a
     * player driving this from the keyboard cannot reach. */
    {
        float bw = 3.0f * AOWL_OV_CW;
        float bx = x + w - AOWL_OV_PAD - bw;
        int32_t hotM = aowl_ov_hit(bx, y + 2.0f, bw, (float)(AOWL_OV_TITLE_H - 4));
        char op[16];
        aowl_ov_rect(bx, y + 2.0f, bw, (float)(AOWL_OV_TITLE_H - 4),
                     hotM ? AOWL_OV_HOT : AOWL_OV_PANEBG);
        aowl_ov_text(bx, y + 5.0f, g_ov.panMax ? "[-]" : "[+]",
                     g_ov.panMax ? AOWL_OV_ACCENT : AOWL_OV_DIM);
        if (hotM && g_ov.clickDown) {
            g_ov.panMax = !g_ov.panMax;
            InterlockedExchange(&g_ov.prefsDirty, 1);
            InterlockedExchange(&g_ov.clickDown, 0);
        }
        aowl_ov_fmt(op, (int32_t)sizeof(op), "%d%%",
                    (g_ov.panAlpha * 100) / 255);
        aowl_ov_text(bx - 6.0f * AOWL_OV_CW, y + 5.0f, op, AOWL_OV_FAINT);
        titleRight = bx - 6.0f * AOWL_OV_CW;
    }
    {
        float tw;
        char cost[48];
        aowl_ov_health(buf, (int32_t)sizeof(buf), &healthCol);
        tw = (float)(strlen(buf) * AOWL_OV_CW);
        aowl_ov_text(titleRight - 8.0f - tw, y + 5.0f, buf, healthCol);
        /* The frame cost, on the title bar, where it is visible from every view
         * -- an overlay in a game's present loop should be made to say what it
         * costs rather than be asked. Microseconds, one decimal, and the worst
         * frame since it opened beside it. */
        /* Dashes until there is a measurement. The first eight drawn frames
         * are dropped from the average deliberately (they are start-up, not the
         * overlay), and the display is refreshed twice a second, so there is a
         * moment after the panel opens with nothing to report -- and `0.0 us`
         * would be a claim rather than a gap.
         *
         * `was`, until this opening has put a time constant's worth of frames
         * into the average. Neither figure is cleared when the panel closes --
         * that is deliberate, and the reason is on `aowl_ov_frame_ns` -- so a
         * reopened panel has the last session's numbers on its title bar and no
         * way to tell that from a measurement of what is on screen now. One
         * word fixes that, and it is the honest one: they are what the cost
         * *was*, the last time this panel was up. (`peak` never comes down at
         * all: it is the worst frame since `aowl_ov_start`, across every
         * opening, which is what makes it worth reading.) */
        if (g_ov.dispAvgNs > 0)
            aowl_ov_fmt(cost, sizeof(cost), "%s%d.%d us  peak %d.%d",
                        g_ov.openDrawn < AOWL_OV_COST_SETTLE ? "was " : "",
                        g_ov.dispAvgNs / 1000, (g_ov.dispAvgNs / 100) % 10,
                        g_ov.dispMaxNs / 1000, (g_ov.dispMaxNs / 100) % 10);
        else
            aowl_ov_fmt(cost, sizeof(cost), "-- us");
        aowl_ov_text(titleRight - 8.0f - tw - 16.0f
                     - (float)(strlen(cost) * AOWL_OV_CW), y + 5.0f,
                     cost, AOWL_OV_FAINT);
    }

    if (g_ov.settings) {
        /* The settings screen's own sub-header, where the tabs and status line
         * would be: how the nav is made up, so the SPT half is never a surprise. */
        float sy = y + (float)AOWL_OV_TITLE_H;
        int32_t mods = 0, spt = 0, k;
        char line[192];
        for (k = 0; k < g_ov.sPageCount; k++)
            if (g_ov.sPages[k].isMod) mods++; else spt++;
        aowl_ov_rect(x + 1.0f, sy, w - 2.0f,
                     (float)(AOWL_OV_TABS_H + AOWL_OV_STAT_H), AOWL_OV_PANEBG);
        /* ONE line, not two, and the second one is gone rather than shortened.
         *
         * It read "every mod config value and the whole SPT server config
         * surface -- pick a page on the left, change a control on the right",
         * which did not fit and rendered as `...pick a page on the left,..` --
         * a sentence cut off mid-clause, above the content, on every frame.
         * It was also instructions for a screen whose own layout says the same
         * thing: there is a list on the left and controls on the right.
         *
         * What is left is the part that is a FACT rather than a hint -- how the
         * nav is made up, so the dimmed SPT half is never a surprise -- and it
         * is measured against the pane before the parenthetical is added, the
         * same rule the search scope line follows. */
        {
            int32_t cols = (int32_t)(innerW / AOWL_OV_CW);
            aowl_ov_fmt(line, (int32_t)sizeof(line),
                        "%d mods  |  %d SPT config sections", mods, spt);
            if ((int32_t)strlen(line) + 26 <= cols) {
                int32_t L = (int32_t)strlen(line);
                _snprintf(line + L, sizeof(line) - 1 - (size_t)L,
                          "  (SPT: not backed yet)");
                line[sizeof(line) - 1] = 0;
            }
            aowl_ov_textn(x + AOWL_OV_PAD, sy + 3.0f, line, AOWL_OV_DIM, cols);
        }
        aowl_ov_view_settings(x, bodyY, innerW, bodyH);
        goto settings_body_done;
    }

    aowl_ov_tabs(x, y + (float)AOWL_OV_TITLE_H, w, counts);

    /* The status line: the manager's own summary, which side it is resolving
     * for, whether it can change anything live, and the active lists. */
    {
        float sy = y + (float)AOWL_OV_TITLE_H + (float)AOWL_OV_TABS_H;
        const char* ctl = g_ov.sControl[0] ? g_ov.sControl : "unknown";
        /* `side` is not repeated here: the manager's summary already ends in
         * "on the server side", and the line was running off the right edge
         * with it. `control` is the one word that decides whether anything on
         * this panel can take effect without a restart, so it stays. */
        /* `game` is the other host in three words, and it comes before `lists`
         * because it is the one segment that decides whether anything on this
         * panel can be said about what is actually loaded in the process the
         * player is looking at. `no host` is not `nothing loaded`: it is the
         * manager saying nobody in the game has spoken to it. */
        char game[40];
        if (!g_ov.sClientHost)
            aowl_ov_fmt(game, sizeof(game), "not reporting");
        else if (g_ov.sClientMore)
            aowl_ov_fmt(game, sizeof(game), "%d rows +more", g_ov.sClientRows);
        else
            aowl_ov_fmt(game, sizeof(game), "%d rows", g_ov.sClientRows);
        aowl_ov_fmt(buf, sizeof(buf), "%s  |  control %s  |  game %s  |  lists %s",
                    g_ov.sSummary[0] ? g_ov.sSummary : "no summary yet", ctl,
                    game, g_ov.sActiveLists[0] ? g_ov.sActiveLists : "none");
        aowl_ov_textn(x + AOWL_OV_PAD, sy + 2.0f, buf,
                      strcmp(ctl, "present") == 0 ? AOWL_OV_DIM : AOWL_OV_WARN,
                      (int32_t)(innerW / AOWL_OV_CW));
    }

    /* --- body --- */
    if (g_ov.view == AOWL_VIEW_MODS)
        aowl_ov_view_mods(x, bodyY, innerW, bodyH, vis, visN, rows);
    else if (g_ov.view == AOWL_VIEW_LISTS)
        aowl_ov_view_lists(x, bodyY, innerW, bodyH, rows);
    else if (g_ov.view == AOWL_VIEW_ISSUES)
        aowl_ov_view_issues(x, bodyY, innerW, bodyH, rows);
    else if (g_ov.view == AOWL_VIEW_APPLY)
        aowl_ov_view_apply(x, bodyY, innerW, bodyH, rows);
    else
        aowl_ov_view_logs(x, bodyY, innerW, bodyH, rows);

settings_body_done:

    /* --- the legend ---
     *
     * Printed, always, on every view. A keyboard interface whose keys are not
     * on screen is a keyboard interface nobody can use, and this one is being
     * driven by somebody whose mouse is busy pointing a rifle. */
    if (g_ov.showFooter) {
        /* Built and measured above; here it is only placed. Both lines are
         * wrapped rather than clipped -- see the note by the measurement. */
        float ly = y + h - legendH + 4.0f;
        aowl_ov_rect(x + 1.0f, ly - 4.0f, w - 2.0f, 1.0f, AOWL_OV_EDGE);
        aowl_ov_wrap(x + AOWL_OV_PAD, ly, legKeys, AOWL_OV_TEXT,
                     legCols, legKeyN);
        aowl_ov_wrap(x + AOWL_OV_PAD, ly + (float)(legKeyN * AOWL_OV_LINE_H),
                     legNote, g_ov.sLastError[0] ? AOWL_OV_ERR : AOWL_OV_FAINT,
                     legCols, legNoteN);
    }

    /* --- MOVING AND RESIZING THE WINDOW ---------------------------------
     *
     * Handled here, at the END of the build, after every control above has had
     * its chance at the click -- so grabbing the title bar cannot also press
     * the MANAGER/SETTINGS toggle or the maximise button that live on it. The
     * cost is that a drag lands on the NEXT frame, which at 60 Hz is 16 ms and
     * is not visible; the alternative was a hit-test ordering that had to be
     * kept in sync with the chrome by hand.
     *
     * Driven by `mouseHeld` rather than by the click edge, because a drag is a
     * held button by definition and `clickDown` is consumed by whatever it
     * lands on. Releasing the button ends the drag and marks the geometry for
     * the WORKER to write out -- never this thread; see `aowl_ov_prefs_save`.
     *
     * Maximised, neither gesture does anything: a maximised window has nowhere
     * to be moved to, and silently un-maximising under a drag is a surprise. */
    {
        float gw = 14.0f;
        int32_t onGrip = aowl_ov_hit(x + w - gw, y + h - gw, gw, gw);
        int32_t onTitle = aowl_ov_hit(x, y, w, (float)AOWL_OV_TITLE_H);
        if (!g_ov.panMax)
            aowl_ov_rect(x + w - gw + 3.0f, y + h - gw + 3.0f, gw - 5.0f,
                         gw - 5.0f,
                         (onGrip || g_ov.dragGrip) ? AOWL_OV_ACCENT : AOWL_OV_EDGE);
        if (g_ov.dragGrip) {
            if (!g_ov.mouseHeld) {
                g_ov.dragGrip = 0;
                /* `savePos` off means the panel opens where it always opens.
                 * The drag still WORKS this session -- it just is not written
                 * back, which is the difference between "cannot move it" and
                 * "does not remember". */
                if (g_ov.savePos) InterlockedExchange(&g_ov.prefsDirty, 1);
            } else {
                g_ov.panW = mxp - g_ov.panX + g_ov.dragDX;
                g_ov.panH = myp - g_ov.panY + g_ov.dragDY;
                if (g_ov.panW < 480.0f) g_ov.panW = 480.0f;
                if (g_ov.panH < 220.0f) g_ov.panH = 220.0f;
            }
        } else if (g_ov.dragWin) {
            if (!g_ov.mouseHeld) {
                g_ov.dragWin = 0;
                if (g_ov.savePos) InterlockedExchange(&g_ov.prefsDirty, 1);
            } else {
                g_ov.panX = mxp - g_ov.dragDX;
                g_ov.panY = myp - g_ov.dragDY;
            }
        } else if (g_ov.mouseHeld && !g_ov.panMax) {
            if (onGrip) {
                g_ov.dragGrip = 1;
                g_ov.dragDX = x + w - mxp;
                g_ov.dragDY = y + h - myp;
            } else if (onTitle) {
                g_ov.dragWin = 1;
                g_ov.dragDX = mxp - x;
                g_ov.dragDY = myp - y;
            }
        }
    }

    /* A click that reached nothing is dropped here rather than saved for the
     * next frame: a queued click fires on whatever happens to be under the
     * cursor a frame later, which is how a mis-click becomes a toggle. */
    InterlockedExchange(&g_ov.clickDown, 0);

    /* Our own cursor. The game hides the OS cursor in a raid and keeps its own
     * ShowCursor count; calling ShowCursor here would fight that counter and
     * leave the cursor stuck when the overlay closes. Drawing a marker costs
     * two quads and touches nothing. */
    {
        float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
        float mx = (float)g_ov.mx / k, my = (float)g_ov.my / k;
        aowl_ov_rect(mx, my, 2.0f, 12.0f, AOWL_OV_TEXT);
        aowl_ov_rect(mx, my, 12.0f, 2.0f, AOWL_OV_TEXT);
    }

    /* Taken *after* the build, because the build itself moves the cursor, the
     * view and the scroll offset. A frame that changes nothing then computes
     * the same signature on the way in next time and stops there. */
    g_ov.drawSig = aowl_ov_signature();
    g_ov.needUpload = 1;
}

static void aowl_ov_draw(IDXGISwapChain* sc) {
    ID3D11DeviceContext* c = g_ov.ctx;

    if (g_ov.vtxCount <= 0) return;

    AowlOvSaved saved;
    aowl_ov_save(c, &saved);

    D3D11_MAPPED_SUBRESOURCE map;
    /* Both uploads are skipped when the geometry did not change. A DYNAMIC
     * buffer keeps its contents unless something discards them, and nothing
     * else in this process has a handle to ours -- so last frame's vertices are
     * still there. `needUpload` is set by `aowl_ov_build` when it rebuilt, and
     * by `aowl_ov_bind` when the device changed underneath us and the buffer is
     * a different buffer. */
    if (g_ov.needUpload) {
    if (SUCCEEDED(ID3D11DeviceContext_Map(c, (ID3D11Resource*)g_ov.vb, 0,
                                          D3D11_MAP_WRITE_DISCARD, 0, &map))) {
        memcpy(map.pData, g_ov.vtx, sizeof(AowlOvVert) * (size_t)g_ov.vtxCount);
        ID3D11DeviceContext_Unmap(c, (ID3D11Resource*)g_ov.vb, 0);
    }
    if (SUCCEEDED(ID3D11DeviceContext_Map(c, (ID3D11Resource*)g_ov.cb, 0,
                                          D3D11_MAP_WRITE_DISCARD, 0, &map))) {
        float* k = (float*)map.pData;
        k[0] =  2.0f / (float)(g_ov.bbW ? g_ov.bbW : 1);
        k[1] = -2.0f / (float)(g_ov.bbH ? g_ov.bbH : 1);
        k[2] = -1.0f;
        k[3] =  1.0f;
        ID3D11DeviceContext_Unmap(c, (ID3D11Resource*)g_ov.cb, 0);
    }
    g_ov.needUpload = 0;
    }

    D3D11_VIEWPORT vp;
    vp.TopLeftX = 0.0f; vp.TopLeftY = 0.0f;
    vp.Width = (float)g_ov.bbW; vp.Height = (float)g_ov.bbH;
    vp.MinDepth = 0.0f; vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(c, 1, &vp);
    ID3D11DeviceContext_RSSetState(c, g_ov.rast);

    /* No depth-stencil view: the overlay must not be depth-tested and must not
     * write depth, and passing NULL is stronger than a state that disables
     * both. */
    ID3D11DeviceContext_OMSetRenderTargets(c, 1, &g_ov.rtv, NULL);
    {
        const FLOAT zero[4] = { 0.0f, 0.0f, 0.0f, 0.0f };
        ID3D11DeviceContext_OMSetBlendState(c, g_ov.blend, zero, 0xFFFFFFFFu);
    }
    ID3D11DeviceContext_OMSetDepthStencilState(c, g_ov.depth, 0);

    UINT stride = sizeof(AowlOvVert), offset = 0;
    ID3D11DeviceContext_IASetInputLayout(c, g_ov.layout);
    ID3D11DeviceContext_IASetVertexBuffers(c, 0, 1, &g_ov.vb, &stride, &offset);
    ID3D11DeviceContext_IASetPrimitiveTopology(c, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(c, g_ov.vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(c, 0, 1, &g_ov.cb);
    ID3D11DeviceContext_PSSetShader(c, g_ov.ps, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(c, 0, 1, &g_ov.font);
    ID3D11DeviceContext_PSSetSamplers(c, 0, 1, &g_ov.samp);
    /* Explicitly unbind the stages we never set. See the header comment: a
     * geometry or tessellation shader left over from the game's last draw
     * would otherwise run on our vertices. */
    ID3D11DeviceContext_GSSetShader(c, NULL, NULL, 0);
    ID3D11DeviceContext_HSSetShader(c, NULL, NULL, 0);
    ID3D11DeviceContext_DSSetShader(c, NULL, NULL, 0);

    /* ---- the draw, in spans ----------------------------------------- *
     *
     * `spanN == 0` is the ONLY path this overlay had before textured quads
     * existed, and it is still bit-for-bit that path: one Draw, the font
     * atlas, the coverage shader. A frame that submits no textured quad never
     * calls `aowl_ov_span_begin`, so it lands here and nothing about the
     * panel, the ESP or the F3 widgets changed.
     *
     * Otherwise the same single vertex buffer is drawn as a sequence of runs,
     * each with its own SRV and, for a tile, the RGBA shader. The loop is
     * bounded by `AOWL_OV_MAX_SPANS`, and a span whose count is <= 0 is
     * skipped rather than issued -- a zero-vertex Draw is legal but pointless
     * and would hide a span-bookkeeping bug behind a no-op. */
    if (g_ov.spanN <= 0) {
        ID3D11DeviceContext_Draw(c, (UINT)g_ov.vtxCount, 0);
    } else {
        int32_t si;
        int32_t nspans = g_ov.spanN;
        if (nspans > AOWL_OV_MAX_SPANS) nspans = AOWL_OV_MAX_SPANS;  /* capped */
        for (si = 0; si < nspans; si++) {
            const AowlOvSpan* sp = &g_ov.spans[si];
            int32_t start = sp->start, count = sp->count;
            if (count <= 0) continue;
            if (start < 0 || start + count > g_ov.vtxCount) continue;  /* refuse */
            if (sp->srv) {
                if (!g_ov.psTex) continue;   /* no textured shader: draw nothing */
                ID3D11DeviceContext_PSSetShader(c, g_ov.psTex, NULL, 0);
                ID3D11DeviceContext_PSSetShaderResources(c, 0, 1,
                    (ID3D11ShaderResourceView* const*)&sp->srv);
            } else {
                ID3D11DeviceContext_PSSetShader(c, g_ov.ps, NULL, 0);
                ID3D11DeviceContext_PSSetShaderResources(c, 0, 1, &g_ov.font);
            }
            ID3D11DeviceContext_Draw(c, (UINT)count, (UINT)start);
        }
    }

    aowl_ov_restore(c, &saved);
}

/* ================================================================== *
 * Input
 * ================================================================== */

/* Latched the first time the spawner query takes a character from WM_KEYDOWN.
 * It exists so the WM_CHAR path can stand down rather than double-enter, on a
 * window that delivers both. Never cleared: a pump that translates messages
 * does not stop doing so mid-session. */
static int32_t g_ov_admQueryFromKeydown = 0;

static LRESULT CALLBACK aowl_ov_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    WNDPROC old = g_ov.oldProc;

    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
        if ((int32_t)wp == g_ov.toggleVk) {
            InterlockedExchange(&g_ov.visible, g_ov.visible ? 0 : 1);
            return 0;                       /* swallowed: never reaches the game */
        }
        /* The admin HUD's own keys, handled outside the panel's `visible` block
         * because the HUD is independent of the mod-manager panel. F6 toggles
         * the menu whether or not the panel is up; the navigation keys are
         * swallowed only while the menu is open, so gameplay keys reach the game
         * the rest of the time. */
        if ((int32_t)wp == VK_F6) {
            aowl_admin_menu_toggle(g_ov_admin);
            return 0;
        }
        if (g_ov_admin && aowl_admin_menu_open(g_ov_admin)) {
            int32_t sel = (int32_t)g_ov_admin->menuSel;
            /* ---- REBIND CAPTURE -------------------------------------------
             * While a capture is in flight the MOD is reading the key, on
             * Unity's thread, through Input::GetKeyDown. This wndproc must
             * therefore not ALSO interpret the press -- so everything is
             * swallowed here. Unity's input does not come from this message
             * pump, so swallowing the message does not hide the key from the
             * capture; it only stops the same press from additionally moving
             * the menu selection or the player.
             *
             * Capture is deliberately resolved on the mod side and not here:
             * a wndproc sees Win32 virtual-keys, and turning those into
             * KeyCodes would mean a 328-entry mapping of hand-typed
             * constants. This way there is exactly one key namespace. */
            if (aowl_admin_hotkey_capturing(g_ov_admin)) return 0;
            /* K on a toggle row starts a rebind; Delete clears one. Both are
             * free: the menu's other keys are already spoken for and neither
             * of these is among them. */
            if ((int32_t)wp == 'K' && aowl_admin_row_is_toggle(sel)) {
                aowl_admin_hotkey_capture_begin(g_ov_admin, sel);
                return 0;
            }
            if ((int32_t)wp == VK_DELETE && aowl_admin_row_is_toggle(sel)) {
                aowl_admin_hotkey_set(g_ov_admin, sel, AOWL_KC_UNBOUND);
                return 0;
            }
            switch ((int32_t)wp) {
                case VK_UP:    aowl_admin_menu_move(g_ov_admin, -1); return 0;
                case VK_DOWN:  aowl_admin_menu_move(g_ov_admin, +1); return 0;
                /* Left/right MEANS something different per row: on a toggle it
                 * is still "flip", on the two spawner number rows it steps the
                 * value, and on the query row it is ignored rather than
                 * silently flipping whatever bit 12 would have been. */
                case VK_LEFT:
                case VK_RIGHT:
                    if (aowl_admin_row_is_toggle(sel)) {
                        aowl_admin_menu_activate(g_ov_admin);
                    } else {
                        aowl_admin_spawn_adjust(g_ov_admin, sel,
                            ((int32_t)wp == VK_RIGHT) ? +1 : -1);
                    }
                    return 0;
                case VK_RETURN:
                case VK_SPACE:
                    /* SPACE on the query row is a SPACE, not an activate --
                     * item names have spaces in them ("m855a1", "grizzly
                     * medical") and swallowing it would make half the
                     * database untypeable. */
                    if (sel == AOWL_ADM_ROW_QUERY && (int32_t)wp == VK_SPACE)
                        aowl_admin_query_putc(g_ov_admin, ' ');
                    else
                        aowl_admin_menu_activate(g_ov_admin);
                    return 0;
                case VK_BACK:
                    if (sel == AOWL_ADM_ROW_QUERY)
                        aowl_admin_query_backspace(g_ov_admin);
                    return 0;
                case VK_ESCAPE: aowl_admin_menu_toggle(g_ov_admin); return 0;
            }
            /* REPORTED DEFECT: "in F6 i cannot type in anything to spawn".
             *
             * This block used to SWALLOW every printable key here and rely on
             * the WM_CHAR handler below to actually enter the character. That
             * makes the spawner query the ONLY text field in this overlay whose
             * input depends on WM_CHAR. The other three -- the settings panel
             * search, the numeric value box and the log search -- all take
             * their text from WM_KEYDOWN through `aowl_ov_vk_char` (see the
             * call sites in `aowl_ov_settings_key` and `aowl_ov_logs_key`), and
             * all three work.
             *
             * That correlation is the evidence: the one field on the WM_CHAR
             * path is the one field the user cannot type into. WM_CHAR is not
             * generated by Windows at all unless the owning message pump calls
             * `TranslateMessage`, and nothing obliges Unity's pump to -- so
             * "the message a key arrives as is a fact about Windows" (the old
             * comment below, which is true) cuts the other way here: the fact
             * is that this window's KEYDOWNs are evidently not being translated.
             *
             * So take the character from WM_KEYDOWN like the fields that work.
             * WM_CHAR is KEPT as a secondary source -- if it does arrive on
             * some configuration it carries real layout and shift information,
             * which `aowl_ov_vk_char` cannot -- but it is suppressed once this
             * path has proven it delivers, so a window that produces BOTH
             * messages enters each keystroke exactly once rather than twice. */
            if (sel == AOWL_ADM_ROW_QUERY) {
                int32_t vk = (int32_t)wp;
                char ch = aowl_ov_vk_char((LONG)wp);
                if (ch) {
                    /* LOWER CASE, for the same reason the panel search does it
                     * -- `aowl_ov_vk_char` hands back the virtual key, which for
                     * a letter is its CAPITAL, so `salewa` would arrive as
                     * `SALEWA`. Here it is not only cosmetic. MEASURED in
                     * `mods/tarkov/emu/spawn.nim`: `searchItemsCounted`
                     * lowercases the query before matching (lines 108/117), so
                     * a name search is unaffected either way -- but the same
                     * query is also tested by `isTemplateId`, and a template id
                     * is lowercase hex. Feeding it uppercase would fail that
                     * test and turn an exact-id spawn into an ambiguous-match
                     * refusal. */
                    if (ch >= 0x41 && ch <= 0x5A) ch = (char)(ch + 32);
                    g_ov_admQueryFromKeydown = 1;
                    aowl_admin_query_putc(g_ov_admin, (int32_t)ch);
                    return 0;
                }
                if ((vk >= '0' && vk <= '9') || (vk >= 'A' && vk <= 'Z') ||
                    (vk >= VK_NUMPAD0 && vk <= VK_DIVIDE) ||
                    (vk >= VK_OEM_1 && vk <= VK_OEM_3) ||
                    (vk >= VK_OEM_4 && vk <= VK_OEM_8))
                    return 0;
            }
        }
    }

    /* WM_CHAR is where TEXT comes from. WM_KEYDOWN carries a virtual-key code,
     * not a character: it does not know the keyboard layout, does not know
     * whether shift was down, and does not produce the right byte for anything
     * but unshifted US letters. Typing an item name therefore has to be read
     * here, in its own message, exactly as F10 has to be read in WM_SYSKEYDOWN
     * rather than WM_KEYDOWN -- the message a key arrives as is a fact about
     * Windows, not something to infer from the key's name.
     *
     * F6 itself is an ordinary key and DOES arrive as WM_KEYDOWN; the block
     * above handles WM_SYSKEYDOWN too, so it is correct either way. */
    if (msg == WM_CHAR && g_ov_admin && aowl_admin_menu_open(g_ov_admin) &&
        (int32_t)g_ov_admin->menuSel == AOWL_ADM_ROW_QUERY) {
        int32_t ch = (int32_t)wp;
        if (ch == '\b') { aowl_admin_query_backspace(g_ov_admin); return 0; }
        if (ch >= 0x20 && ch <= 0x7E) {
            /* Suppressed once WM_KEYDOWN has been shown to deliver -- see the
             * block above. Still SWALLOWED (return 0) rather than passed on:
             * the menu has focus and the letter must not also move the player. */
            if (!g_ov_admQueryFromKeydown)
                aowl_admin_query_putc(g_ov_admin, ch);
            return 0;
        }
        /* A character outside printable ASCII is swallowed rather than passed
         * on: the menu has focus, and letting it through would move the player
         * while they are typing. */
        return 0;
    }

    if (g_ov.visible) {
        switch (msg) {
        case WM_MOUSEMOVE: {
            /* Absolute position, valid whenever the game is not locking the
             * cursor. In a raid it does lock it, and then WM_MOUSEMOVE stops
             * arriving (or arrives clamped) -- which is what the WM_INPUT case
             * below is for. */
            InterlockedExchange(&g_ov.mx, (LONG)(short)LOWORD(lp));
            InterlockedExchange(&g_ov.my, (LONG)(short)HIWORD(lp));
            return 0;
        }
        case WM_INPUT: {
            /* Raw mouse input, which is how Unity reads the mouse for camera
             * look. If we only swallowed WM_MOUSEMOVE the player would still be
             * spinning the camera while clicking a button in the panel.
             *
             * DefWindowProc must still see WM_INPUT -- it is what frees the
             * raw input buffer -- but the *game's* WndProc must not, so we call
             * DefWindowProc ourselves and return its result. */
            RAWINPUT ri;
            UINT sz = sizeof(ri);
            if (GetRawInputData((HRAWINPUT)lp, RID_INPUT, &ri, &sz,
                                sizeof(RAWINPUTHEADER)) != (UINT)-1 &&
                ri.header.dwType == RIM_TYPEMOUSE &&
                (ri.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0) {
                LONG nx = g_ov.mx + ri.data.mouse.lLastX;
                LONG ny = g_ov.my + ri.data.mouse.lLastY;
                if (nx < 0) nx = 0;
                if (ny < 0) ny = 0;
                if (g_ov.bbW && nx > (LONG)g_ov.bbW - 1) nx = (LONG)g_ov.bbW - 1;
                if (g_ov.bbH && ny > (LONG)g_ov.bbH - 1) ny = (LONG)g_ov.bbH - 1;
                InterlockedExchange(&g_ov.mx, nx);
                InterlockedExchange(&g_ov.my, ny);
                InterlockedExchange(&g_ov.cursorLocked, 1);
            }
            return DefWindowProcW(hwnd, msg, wp, lp);
        }
        case WM_LBUTTONDOWN:
        case WM_LBUTTONDBLCLK:
            InterlockedExchange(&g_ov.clickDown, 1);
            InterlockedExchange(&g_ov.mouseHeld, 1);
            return 0;
        case WM_MOUSEWHEEL:
            /* One notch is WHEEL_DELTA, and a high-resolution wheel sends
             * fractions of one. Accumulating the raw value and dividing on the
             * render thread would drop every fraction; accumulating notches
             * here loses nothing a list can use. */
            InterlockedExchangeAdd(&g_ov.wheel,
                                   (LONG)GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA);
            return 0;
        case WM_LBUTTONUP:
            /* The render thread ends a slider drag when it sees this fall to 0.
             * Cleared here rather than on consume, unlike `clickDown`, because a
             * held button is a state and a click is an event. */
            InterlockedExchange(&g_ov.mouseHeld, 0);
            return 0;
        case WM_RBUTTONDOWN:
        case WM_RBUTTONUP:
        case WM_MBUTTONDOWN:
        case WM_MBUTTONUP:
        case WM_KEYUP:
        case WM_SYSKEYUP:
        case WM_CHAR:
        /* WM_SYSCHAR is swallowed for the same reason WM_SYSKEYDOWN is taken
         * below: without it, every system-key press Windows did not get to
         * turn into a menu produces the default BEEP. A panel that beeps at
         * you for pressing its own opacity key reads as a panel refusing the
         * key -- which is the exact wrong signal here. */
        case WM_SYSCHAR:
            return 0;
        case WM_SYSKEYDOWN:
            /* ---- F10 ARRIVES HERE, NOT AT WM_KEYDOWN. This was the bug. ----
             *
             * F10 is Windows' menu-activation key, so the system delivers it
             * as WM_SYSKEYDOWN even with no Alt held -- and so does any key
             * pressed WITH Alt down. This switch only had WM_KEYDOWN, so F10
             * fell through to `default: break;` and on to the game's wndproc:
             * it never reached `aowl_ov_push_key`, never reached
             * `aowl_ov_keys`, and `panAlpha` was never touched. F9 is an
             * ordinary WM_KEYDOWN and worked, which is exactly the reported
             * asymmetry -- "F10 still does not make the fade darker ... it
             * works only in one direction".
             *
             * The handler was symmetric the whole time (`+27` against `-27`
             * with the same clamp); nothing about the VALUE was ever wrong.
             * Three candidate bugs -- wrong sign, saturating clamp, key never
             * fires -- and it was the third. Worth stating plainly, because
             * the two arithmetic ones are what the code invites you to
             * suspect, and the message routing is invisible from the handler.
             *
             * ALT+F4 IS THE ONE EXCEPTION and must keep closing the game.
             * Bit 29 of lParam is the context code: set means Alt was down. So
             * Alt+F4 goes to the game and everything else -- bare F10, and any
             * other Alt combination, which must not walk the player around
             * behind an open panel -- is taken exactly like a normal key. */
            if ((int32_t)wp == VK_F4 && (lp & (1 << 29)))
                break;                       /* -> the game's wndproc */
            aowl_ov_push_key((LONG)wp);
            return 0;
        case WM_SYSCOMMAND:
            /* And the other half of the same key. Even with WM_SYSKEYDOWN
             * swallowed, DefWindowProc can still be asked to open the window
             * menu via SC_KEYMENU -- which grabs focus and stops the game
             * presenting until it is dismissed. A panel key must never be able
             * to freeze the client. */
            if ((wp & 0xFFF0) == SC_KEYMENU) return 0;
            break;
        case WM_KEYDOWN:
            /* Every key is eaten while the panel is open -- WASD must not walk
             * the player into a wall behind a menu -- and the ones the panel
             * uses are queued for the render thread to act on.
             *
             * Queued rather than acted on here, and that is not fussiness: this
             * is the *window* thread, and the UI state it would be changing is
             * read by the render thread every frame. Doing the work here would
             * mean either a lock the wndproc can block on (a window that stops
             * pumping while the GPU is busy shows as "not responding") or a
             * cursor that moves halfway through a frame's layout. */
            /* ESC closes the panel -- UNLESS something on it owns ESC first.
             * The search box (and an in-progress text or keybind edit) uses
             * ESC to back out of itself, and a text field whose cancel key
             * shuts the whole window instead is a text field nobody can back
             * out of. Those cases go into the ring like any other key and the
             * render thread`s handler consumes them; only a bare ESC with
             * nothing to cancel closes.
             *
             * Read here rather than queued because the decision is "who owns
             * this key", not "what does it do" -- and getting it wrong is not
             * a cursor landing on the wrong row, it is the panel vanishing. */
            if (wp == VK_ESCAPE) {
                int32_t owned = (g_ov.settings &&
                                 (g_ov.searchFocus || g_ov.search[0] ||
                                  g_ov.editItem >= 0 || g_ov.capturing)) ||
                                (!g_ov.settings &&
                                 g_ov.view == AOWL_VIEW_LOGS &&
                                 (g_ov.logSearchFocus || g_ov.logSearch[0]));
                if (!owned) { InterlockedExchange(&g_ov.visible, 0); return 0; }
            }
            aowl_ov_push_key((LONG)wp);
            return 0;
        default:
            break;
        }
    }

    return CallWindowProcW(old, hwnd, msg, wp, lp);
}

static void aowl_ov_attach_window(HWND hwnd) {
    if (g_ov.hwnd == hwnd) return;
    if (g_ov.hwnd && g_ov.oldProc) {
        SetWindowLongPtrW(g_ov.hwnd, GWLP_WNDPROC, (LONG_PTR)g_ov.oldProc);
        g_ov.oldProc = NULL;
    }
    g_ov.hwnd = hwnd;
    if (!hwnd) return;
    /* Subclassing by swapping GWLP_WNDPROC rather than hooking GetMessage:
     * a message hook only sees messages that go through the queue, and both
     * WM_INPUT and anything the game sends itself with SendMessage bypass it.
     * The window proc sees everything by construction. */
    g_ov.oldProc = (WNDPROC)(LONG_PTR)SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                                                        (LONG_PTR)aowl_ov_wndproc);
}

/* ================================================================== *
 * The hooks
 * ================================================================== */

typedef HRESULT (STDMETHODCALLTYPE *AowlPresentFn)(IDXGISwapChain*, UINT, UINT);
typedef HRESULT (STDMETHODCALLTYPE *AowlResizeFn)(IDXGISwapChain*, UINT, UINT, UINT,
                                                  DXGI_FORMAT, UINT);

static int32_t aowl_ov_bind(IDXGISwapChain* sc) {
    if (g_ov.swap == sc && g_ov.rtv) return 1;

    if (g_ov.swap != sc) {
        /* A different swap chain (or the first one). Everything device-bound is
         * torn down: objects created on one device cannot be used on another,
         * and a game that recreates its device on an alt-tab or a resolution
         * change gets a fresh one rather than a crash. */
        aowl_ov_release_all();
        g_ov.swap = sc;
        if (FAILED(IDXGISwapChain_GetDevice(sc, &AOWL_IID_ID3D11Device,
                                            (void**)&g_ov.dev)) || !g_ov.dev) {
            /* Not a D3D11 swap chain -- a D3D12 or D3D10 game would land here.
             * Not an error we can fix, and not one worth latching `broken` for
             * if some other swap chain in the process is D3D11, but for Tarkov
             * it means the overlay simply does not run. */
            g_ov.swap = NULL;
            aowl_ov_fail("swap chain is not D3D11");
            return 0;
        }
        ID3D11Device_GetImmediateContext(g_ov.dev, &g_ov.ctx);
        if (!g_ov.ctx) { aowl_ov_fail("no immediate context"); return 0; }
        if (!aowl_ov_make_device_objects()) {
            aowl_ov_fail("could not create the overlay's D3D11 objects");
            return 0;
        }
    }
    if (!g_ov.rtv && !aowl_ov_make_rtv(sc)) {
        aowl_ov_fail("could not create a render target view on the back buffer");
        return 0;
    }
    /* The back buffer may be a different size now, and after a device change
     * the vertex buffer is a different buffer with nothing in it. Both mean the
     * geometry cache must not be trusted for the next frame -- a zero signature
     * never matches one `aowl_ov_signature` can produce. */
    if (g_ov.bbW != g_ov.sigBbW || g_ov.bbH != g_ov.sigBbH) {
        g_ov.sigBbW = g_ov.bbW;
        g_ov.sigBbH = g_ov.bbH;
        g_ov.drawSig = 0;
        g_ov.needUpload = 1;
    }
    {
        DXGI_SWAP_CHAIN_DESC d;
        if (SUCCEEDED(IDXGISwapChain_GetDesc(sc, &d)) && d.OutputWindow)
            aowl_ov_attach_window(d.OutputWindow);
    }
    aowl_ov_note("overlay running");
    return 1;
}

/* ================================================================== *
 * The admin / cheat HUD
 *
 * A HUD drawn on the game's own frame, inside this same Present hook, from the
 * shared region the mod publishes. It is NOT the mod-manager panel above -- it
 * has no backend, no rows, no keyboard-driven list -- it is ESP boxes and a
 * small F6 toggle menu, the standard shape of an in-game cheat overlay. It
 * reuses the overlay's proven D3D11 pipeline and 8x16 font rather than standing
 * up a second one, because a HUD and a panel want exactly the same primitives.
 *
 * Everything here is read-only against the shared region and bounded, and every
 * entry is guarded on `g_ov_admin` being mapped, so an absent or stale producer
 * is a HUD that draws nothing rather than a fault.
 * ================================================================== */

static uint32_t aowl_ov_admin_side_col(int32_t side) {
    switch (side) {
        case AOWL_ADM_SIDE_FRIEND: return AOWL_RGBA(90, 175, 110, 255);
        case AOWL_ADM_SIDE_ENEMY:  return AOWL_RGBA(224, 92, 92, 255);
        case AOWL_ADM_SIDE_SCAV:   return AOWL_RGBA(224, 184, 80, 255);
        case AOWL_ADM_SIDE_BOSS:   return AOWL_RGBA(230, 120, 220, 255);
        default:                   return AOWL_RGBA(210, 214, 220, 255);
    }
}

/* Whether the HUD wants to draw this frame: the menu is open, or ESP is on and
 * the mod says it is in a raid. Cheap, so it gates the whole build path in
 * Present without measuring anything. */
static int32_t aowl_ov_admin_active(void) {
    if (!g_ov_admin || g_ov_admin->magic != AOWL_ADM_MAGIC) return 0;
    if (aowl_admin_menu_open(g_ov_admin)) return 1;
    if (aowl_admin_toggle_get(g_ov_admin, AOWL_ADM_ESP) && g_ov_admin->inRaid)
        return 1;
    return 0;
}

/* The consumer's stable copy of the frame, taken under the seqlock. Static
 * because the render thread is the only reader and a per-frame stack copy of a
 * 256-entity frame is a needless 10 KB memmove on the stack.
 *
 * TWO slots, not one, so the reader can HOLD the last good committed frame
 * (task: the ESP FLICKER). `aowl_admin_snapshot` writes incrementally into its
 * `out` and returns 0 on a torn read (the publisher's odd-seqlock window on
 * the host thread overlapping this render-thread read) -- leaving that buffer
 * half-written. The old single-slot reader then drew NOTHING that Present, so a
 * torn read blanked every box for one frame; at 144Hz against a per-Unity-frame
 * publisher that lands on a large fraction of Presents and reads as flicker.
 * The publisher's committed frame persists in the shared region until the next
 * commit, so the correct behaviour is to re-draw the last frame we successfully
 * copied whenever this Present's copy tears. We snapshot into the BACK slot and
 * only flip `g_ovAdminSnapCur` to it on success; a torn read leaves the front
 * slot (the last good frame) untouched and we draw that. `-1` means we have not
 * yet copied any good frame this raid. */
static AowlAdminShared g_ovAdminSnap[2];
static int32_t         g_ovAdminSnapCur = -1;

/* ------------------------------------------------------------------ *
 * WHICH PANELS WANT THE MOUSE
 *
 * In a raid the client holds the cursor with `CursorLockMode.Locked` and pins
 * it to the screen centre every frame, so these panels draw perfectly and
 * cannot be clicked. Freeing it means calling `UnityEngine.Cursor`'s own
 * setters, which is MANAGED code and must happen on Unity's main thread -- and
 * this is the RENDER thread. So the overlay does not free anything. It only
 * says, once per Present, which of its panels are currently open; the host
 * reads that on its `TarkovApplication::Update` drain and does the rest.
 * `abi/aowlspt_cursor.h` is the whole facility.
 *
 * The publication is a LEVEL, not an edge: the full mask goes out every frame,
 * including 0. That is what lets the host release the cursor by itself if this
 * module stops running, rather than stranding the player with a freed cursor in
 * a firefight -- and it is why there is no "close" event to forget to send.
 *
 * The F6 admin MENU counts; the admin ESP does NOT. ESP is a passive draw over
 * the world with nothing to click, and taking mouselook control away from a
 * player who merely has ESP on would be a regression rather than a feature.
 *
 * Resolved by `GetProcAddress` on the host DLL exactly as `aowl_region_commands`
 * is, and for the same reason: a host too old to export it must be a clean
 * "nothing published", never a load failure.
 * ------------------------------------------------------------------ */
typedef int32_t (*AowlOvCursorFn)(int32_t);
static AowlOvCursorFn aowl_ov_cursor_fn  = 0;
static int32_t        aowl_ov_cursor_try = 0;

static void aowl_ov_publish_cursor_panels(void) {
    int32_t mask = 0;
    if (!aowl_ov_cursor_try) {
        HMODULE h;
        aowl_ov_cursor_try = 1;
        h = GetModuleHandleA("aowlspt-host-il2cpp.dll");
        if (h)
            aowl_ov_cursor_fn = (AowlOvCursorFn)(void*)
                GetProcAddress(h, "aowl_cursor_panels_x");
    }
    if (!aowl_ov_cursor_fn) return;
    if (g_ov.visible) mask |= (int32_t)AOWL_CUR_P_OVERLAY;
    if (g_ov_admin && g_ov_admin->magic == AOWL_ADM_MAGIC &&
        aowl_admin_menu_open(g_ov_admin))
        mask |= (int32_t)AOWL_CUR_P_ADMIN;
    aowl_ov_cursor_fn(mask);
}

/* ------------------------------------------------------------------ *
 * THE SHARED REGION'S DRAW
 *
 * The generic replacement for what `aowl_ov_admin_append` does privately for
 * one mod. Every participant that registered a DRAW callback with
 * `abi/aowlspt_region.h` submitted screen-space commands on the Unity thread;
 * this drains the published buffer here, on the render thread, and rasterises
 * it with the same primitives the panel uses.
 *
 * The overlay is its own module, so it is a plain CLIENT of the region: it
 * resolves `aowl_region_commands_x` by GetProcAddress on the host DLL, and a
 * host that predates the region simply returns 0 commands. Nothing here can
 * fault the game -- an absent host is an empty frame, exactly as an absent
 * admin mod is an empty HUD.
 *
 * True back-buffer pixels: the submitter already projected to pixels, so the
 * panel's integer scale is forced to 1 across this and restored after, the
 * same discipline the admin ESP append follows.
 * ------------------------------------------------------------------ */

/* ================================================================== *
 * TEXTURED QUADS: the span list and the GPU tile cache
 *
 * The rule this obeys, and the reason it is here rather than anywhere else:
 * the region contract says the Unity thread PUBLISHES and the render thread
 * DRAINS, and nothing about textures changes that. The host's CPU table (see
 * `aowl_region_texture_define`) holds bytes and keys and never touches D3D11;
 * every function below runs on the render thread, inside Present, and is the
 * only code that owns a device object. There is no second submission path and
 * no cross-thread ownership.
 * ================================================================== */

/* Start emitting into a run drawn with `srv` (NULL = the font atlas and the
 * coverage shader, i.e. everything the overlay has always drawn).
 *
 * Consecutive calls with the same `srv` COALESCE, so a map that submits its
 * tiles in key order costs one span per tile rather than one per quad. */
static void aowl_ov_span_begin(ID3D11ShaderResourceView* srv) {
    AowlOvSpan* p;
    if (g_ov.spanN == 0) {
        /* Everything emitted so far this frame -- panel, ESP, text -- is the
         * font run, and it is span 0. A frame that never calls this keeps
         * spanN == 0 and takes the original single-Draw path unchanged. */
        g_ov.spans[0].start = 0;
        g_ov.spans[0].count = g_ov.vtxCount;
        g_ov.spans[0].srv   = NULL;
        g_ov.spanN = 1;
        if (srv == NULL) return;
        if (g_ov.spans[0].count <= 0) { g_ov.spans[0].srv = srv; return; }
    } else {
        p = &g_ov.spans[g_ov.spanN - 1];
        if (p->srv == srv) return;                    /* coalesce */
        p->count = g_ov.vtxCount - p->start;
        if (p->count <= 0) { p->srv = srv; return; }  /* empty: retarget */
    }
    if (g_ov.spanN >= AOWL_OV_MAX_SPANS) {
        /* Counted, and the geometry stays in the PREVIOUS span rather than
         * being dropped. A tile drawn with the wrong texture is visible and
         * gets reported; a hole reads as "the map did not load". */
        g_ov.texMisses++;
        return;
    }
    p = &g_ov.spans[g_ov.spanN++];
    p->start = g_ov.vtxCount;
    p->count = 0;
    p->srv   = srv;
}

static void aowl_ov_span_close(void) {
    if (g_ov.spanN > 0) {
        AowlOvSpan* p = &g_ov.spans[g_ov.spanN - 1];
        p->count = g_ov.vtxCount - p->start;
    }
}

static DXGI_FORMAT aowl_ov_tex_dxgi(int32_t fmt) {
    switch (fmt) {
        case AOWL_REGION_TEXFMT_BGRA8: return DXGI_FORMAT_B8G8R8A8_UNORM;
        case AOWL_REGION_TEXFMT_BC7:   return DXGI_FORMAT_BC7_UNORM;
        case AOWL_REGION_TEXFMT_BC3:   return DXGI_FORMAT_BC3_UNORM;
        case AOWL_REGION_TEXFMT_BC1:   return DXGI_FORMAT_BC1_UNORM;
        default:                       return DXGI_FORMAT_UNKNOWN;
    }
}

/* The SRV for a key, uploading it once if this is the first sight of it (or
 * if the host redefined it, which `gen` and only `gen` can tell us).
 *
 * Returns NULL for: no device, no such key in the host's table, an unknown
 * format, a failed create, or a full cache with nothing evictable. Every one
 * of those makes the caller COUNT A MISS and draw nothing, which is the only
 * honest option -- drawing the quad untextured would paint the font atlas
 * across the map's footprint. */
static ID3D11ShaderResourceView* aowl_ov_tex_srv(uint64_t key, int64_t frame) {
    const AowlRegionTexSlot* slot = 0;
    AowlOvTexEntry* e;
    int32_t i, victim = -1;
    int64_t oldest = 0;
    D3D11_TEXTURE2D_DESC td;
    D3D11_SUBRESOURCE_DATA sd;
    ID3D11Texture2D* tex = NULL;
    ID3D11ShaderResourceView* srv = NULL;
    DXGI_FORMAT dxgi;
    uint32_t pitch;

    if (!key || !g_ov.dev) return NULL;

    /* The host's table is AOWL_REGION_TEX_MAX slots; capped, and the cap is
     * the loop bound, so a corrupt count cannot spin here. */
    for (i = 0; i < AOWL_REGION_TEX_MAX; i++) {
        const AowlRegionTexSlot* t = aowl_region_texture_slot(i);
        if (t && t->key == key) { slot = t; break; }
    }
    if (!slot) return NULL;

    for (i = 0; i < AOWL_OV_TEX_MAX; i++) {
        e = &g_ov.texc[i];
        if (e->key == key && e->srv) {
            if (e->gen == slot->gen) { e->lastFrame = frame; return e->srv; }
            /* Redefined under the same key. Drop and rebuild -- this is the
             * case a key-only cache gets silently wrong. */
            ID3D11ShaderResourceView_Release(e->srv);
            e->srv = NULL; e->key = 0;
        }
    }

    dxgi = aowl_ov_tex_dxgi(slot->fmt);
    if (dxgi == DXGI_FORMAT_UNKNOWN) return NULL;
    if (slot->w <= 0 || slot->h <= 0) return NULL;
    if (aowl_region_tex_bytes(slot->fmt, slot->w, slot->h) != slot->bytes)
        return NULL;   /* the table disagrees with itself: refuse, never guess */

    if (slot->fmt == AOWL_REGION_TEXFMT_BGRA8) {
        pitch = (uint32_t)slot->w * 4u;
    } else {
        uint32_t blockBytes = (slot->fmt == AOWL_REGION_TEXFMT_BC1) ? 8u : 16u;
        pitch = (((uint32_t)slot->w + 3u) / 4u) * blockBytes;
    }

    for (i = 0; i < AOWL_OV_TEX_MAX; i++) {
        e = &g_ov.texc[i];
        if (!e->srv) { victim = i; break; }
        if (e->lastFrame >= frame) continue;    /* drawn this frame already */
        if (victim < 0 || e->lastFrame < oldest) { victim = i; oldest = e->lastFrame; }
    }
    if (victim < 0) return NULL;

    memset(&td, 0, sizeof(td));
    td.Width = (UINT)slot->w;
    td.Height = (UINT)slot->h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = dxgi;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    memset(&sd, 0, sizeof(sd));
    sd.pSysMem = slot->data;
    sd.SysMemPitch = (UINT)pitch;

    if (FAILED(ID3D11Device_CreateTexture2D(g_ov.dev, &td, &sd, &tex)))
        return NULL;
    if (FAILED(ID3D11Device_CreateShaderResourceView(g_ov.dev,
                (ID3D11Resource*)tex, NULL, &srv))) {
        ID3D11Texture2D_Release(tex);
        return NULL;
    }
    ID3D11Texture2D_Release(tex);

    e = &g_ov.texc[victim];
    if (e->srv) ID3D11ShaderResourceView_Release(e->srv);
    e->srv = srv; e->key = key; e->gen = slot->gen; e->lastFrame = frame;
    g_ov.texUploads++;
    return srv;
}

/* Six vertices, one textured quad. Deliberately NOT `aowl_ov_rect`: that one
 * pins every vertex to the atlas's opaque texel, which is exactly what a
 * textured quad must not do. */
static void aowl_ov_tex_quad(float x, float y, float w, float h,
                             float u0, float v0, float u1, float v1,
                             uint32_t tint) {
    if (g_ov.vtxCount + 6 > AOWL_OV_MAX_VERTS) { g_ov.vtxDropped += 6; return; }
    aowl_ov_vert(x,     y,     u0, v0, tint);
    aowl_ov_vert(x + w, y,     u1, v0, tint);
    aowl_ov_vert(x,     y + h, u0, v1, tint);
    aowl_ov_vert(x + w, y,     u1, v0, tint);
    aowl_ov_vert(x + w, y + h, u1, v1, tint);
    aowl_ov_vert(x,     y + h, u0, v1, tint);
}

/* One ROTATED textured quad. The dest rect's four corners are rotated about the
 * pivot (px,py) by the pre-computed (rcos,rsin) -- see the note on
 * AowlRegionCmd for the exact formula and why cos/sin are passed rather than an
 * angle (the overlay stays free of <math.h> and the trig is one call per frame
 * upstream, not one per tile). When clipW>0 && clipH>0 the rotated quad is
 * clipped to the axis-aligned rect (clipX..clipX+clipW, clipY..clipY+clipH) by
 * Sutherland-Hodgman with the UV interpolated affinely at each new vertex, then
 * emitted as a triangle fan; without a clip it is the two triangles the corners
 * make. Fixed local arrays, no allocation; the polygon is at most 8 vertices
 * (a rectangle cut by four half-planes), so at most 6 triangles / 18 verts. */
typedef struct { float x, y, u, v; } AowlOvClipV;

static void aowl_ov_tex_quad_rot(float x, float y, float w, float h,
                                 float u0, float v0, float u1, float v1,
                                 float rcos, float rsin, float px, float py,
                                 float clipX, float clipY,
                                 float clipW, float clipH,
                                 uint32_t tint) {
    AowlOvClipV in[8], out[8];
    int32_t nin = 0, i, e;
    /* Corners TL, TR, BR, BL with their UVs, rotated about the pivot. */
    const float cxs[4] = { x,     x + w, x + w, x     };
    const float cys[4] = { y,     y,     y + h, y + h };
    const float cus[4] = { u0,    u1,    u1,    u0    };
    const float cvs[4] = { v0,    v0,    v1,    v1    };
    for (i = 0; i < 4; i++) {
        float dx = cxs[i] - px, dy = cys[i] - py;
        in[i].x = px + dx * rcos - dy * rsin;
        in[i].y = py + dx * rsin + dy * rcos;
        in[i].u = cus[i];
        in[i].v = cvs[i];
    }
    nin = 4;

    if (clipW > 0.0f && clipH > 0.0f) {
        /* Four half-planes, each "keep points with nx*X + ny*Y <= d". */
        float ex[4] = { -1.0f, 1.0f,  0.0f, 0.0f };
        float ey[4] = {  0.0f, 0.0f, -1.0f, 1.0f };
        float ed[4] = { -clipX, clipX + clipW, -clipY, clipY + clipH };
        for (e = 0; e < 4 && nin > 0; e++) {
            int32_t nout = 0, j;
            for (j = 0; j < nin; j++) {
                AowlOvClipV A = in[j];
                AowlOvClipV B = in[(j + 1) % nin];
                float da = ex[e] * A.x + ey[e] * A.y - ed[e];
                float db = ex[e] * B.x + ey[e] * B.y - ed[e];
                int32_t Ain = (da <= 0.0f), Bin = (db <= 0.0f);
                if (Ain && nout < 8) out[nout++] = A;
                if (Ain != Bin) {
                    float denom = da - db;
                    float tpar = (denom != 0.0f) ? da / denom : 0.0f;
                    AowlOvClipV I;
                    I.x = A.x + tpar * (B.x - A.x);
                    I.y = A.y + tpar * (B.y - A.y);
                    I.u = A.u + tpar * (B.u - A.u);
                    I.v = A.v + tpar * (B.v - A.v);
                    if (nout < 8) out[nout++] = I;
                }
            }
            nin = nout;
            for (j = 0; j < nin; j++) in[j] = out[j];
        }
    }

    if (nin < 3) return;                       /* fully clipped away */
    if (g_ov.vtxCount + (nin - 2) * 3 > AOWL_OV_MAX_VERTS) {
        g_ov.vtxDropped += (nin - 2) * 3; return;
    }
    for (i = 1; i + 1 < nin; i++) {
        aowl_ov_vert(in[0].x,     in[0].y,     in[0].u,     in[0].v,     tint);
        aowl_ov_vert(in[i].x,     in[i].y,     in[i].u,     in[i].v,     tint);
        aowl_ov_vert(in[i + 1].x, in[i + 1].y, in[i + 1].u, in[i + 1].v, tint);
    }
}

static void aowl_ov_region_append(void) {
    const AowlRegionCmd* cmds = 0;
    int32_t n = aowl_region_commands(&cmds);
    int32_t i, savedScale;
    if (n <= 0 || !cmds) return;
    if (n > AOWL_REGION_MAX_CMDS) n = AOWL_REGION_MAX_CMDS;  /* capped */
    savedScale = g_ov.scale;
    g_ov.scale = 1;
    for (i = 0; i < n; i++) {
        const AowlRegionCmd* c = &cmds[i];
        switch (c->kind) {
            case AOWL_REGION_CMD_FILL:
                aowl_ov_rect(c->x, c->y, c->w, c->h, c->col);
                break;
            case AOWL_REGION_CMD_BOX:
                aowl_ov_frame_rect(c->x, c->y, c->w, c->h,
                                   c->t > 0.0f ? c->t : 1.0f, c->col);
                break;
            case AOWL_REGION_CMD_TEXT: {
                /* TEXT REUSES `t` AS AN INTEGER FONT SCALE. `t` has no meaning
                 * for a text command and every existing submitter leaves it 0,
                 * so 0 (and anything < 1) is exactly the old 1x behaviour --
                 * this is additive, not an ABI change, and no mod had to be
                 * rebuilt for it.
                 *
                 * WHY IT WAS NEEDED. An 8x16 cell on a 3840x2160 back buffer is
                 * unreadable, and the F3 widgets are a read-out a human is
                 * meant to READ. The panel and the F6 menu already pick an
                 * integer scale for exactly this reason; a region submitter had
                 * no way to say so and was pinned at 1x.
                 *
                 * The submitter still works in TRUE BACK-BUFFER PIXELS: the
                 * scale is applied inside `aowl_ov_vert`, which multiplies the
                 * position as well as the glyph, so the position is divided out
                 * here. A submitter that had to pre-divide would be a second
                 * coordinate system to get wrong. */
                int32_t k = (int32_t)c->t;
                if (k < 1) k = 1;
                if (k > 8) k = 8;          /* capped; never trusted raw */
                g_ov.scale = k;
                aowl_ov_text(c->x / (float)k, c->y / (float)k, c->text, c->col);
                g_ov.scale = 1;
                break;
            }
            case AOWL_REGION_CMD_LINE: {
                /* An axis-aligned quad between the two points. The overlay has
                 * no line primitive and inventing a rotated one here would be
                 * a second rasteriser to maintain; a thin rect is what the
                 * admin HUD's own "lines" already are. */
                float x0 = c->x, y0 = c->y, x1 = c->w, y1 = c->h;
                float t  = c->t > 0.0f ? c->t : 1.0f;
                float lx = x0 < x1 ? x0 : x1, ly = y0 < y1 ? y0 : y1;
                float w  = (x1 > x0 ? x1 - x0 : x0 - x1);
                float h  = (y1 > y0 ? y1 - y0 : y0 - y1);
                if (w < t) w = t;
                if (h < t) h = t;
                if (w <= t || h <= t) aowl_ov_rect(lx, ly, w, h, c->col);
                break;
            }
            case AOWL_REGION_CMD_QUAD: {
                /* THE ONLY PLACE ARTWORK ENTERS THE OVERLAY.
                 *
                 * Every failure here is a COUNTED MISS that draws nothing.
                 * The tempting fallback -- emit the quad anyway and let the
                 * font atlas be sampled -- would put recognisable glyph soup
                 * exactly where the map belongs, and that reads as a renderer
                 * bug rather than as the cache miss it actually is. */
                ID3D11ShaderResourceView* srv;
                if (!g_ov.psTex) { g_ov.texMisses++; break; }
                if (c->w <= 0.0f || c->h <= 0.0f) break;
                srv = aowl_ov_tex_srv(c->tex, aowl_region_frames());
                if (!srv) { g_ov.texMisses++; break; }
                aowl_ov_span_begin(srv);
                aowl_ov_tex_quad(c->x, c->y, c->w, c->h,
                                 c->u0, c->v0, c->u1, c->v1, c->col);
                break;
            }
            case AOWL_REGION_CMD_QUADR: {
                /* The rotated sibling of QUAD -- heading-up map art. Same
                 * residency contract (a cache miss is a COUNTED MISS that draws
                 * nothing, never the font atlas), same span/SRV path; only the
                 * geometry differs: the four dest corners are rotated about the
                 * pivot and clipped to the pane before the triangles are made. */
                ID3D11ShaderResourceView* srv;
                if (!g_ov.psTex) { g_ov.texMisses++; break; }
                if (c->w <= 0.0f || c->h <= 0.0f) break;
                srv = aowl_ov_tex_srv(c->tex, aowl_region_frames());
                if (!srv) { g_ov.texMisses++; break; }
                aowl_ov_span_begin(srv);
                aowl_ov_tex_quad_rot(c->x, c->y, c->w, c->h,
                                     c->u0, c->v0, c->u1, c->v1,
                                     c->rcos, c->rsin, c->rpx, c->rpy,
                                     c->rclipX, c->rclipY, c->rclipW, c->rclipH,
                                     c->col);
                break;
            }
            default: break;
        }
    }
    /* Back to the font run before returning, unconditionally. Anything the
     * overlay appends AFTER this -- the launch hint, notably -- would
     * otherwise be rasterised with the last tile's texture bound. This is a
     * no-op when no quad was drawn. */
    if (g_ov.spanN > 0) {
        aowl_ov_span_begin(NULL);
        aowl_ov_span_close();
    }
    g_ov.scale = savedScale;
}

/* Append the HUD's geometry into the overlay's vertex scratch, to be flushed by
 * the one `aowl_ov_draw` the Present body already issues. ESP is drawn in true
 * back-buffer pixels (scale forced to 1, since the mod already projected to
 * pixels); the menu is drawn at the panel's integer scale so its text is legible
 * at 4K. */
static void aowl_ov_admin_append(void) {
    if (!g_ov_admin || g_ov_admin->magic != AOWL_ADM_MAGIC) return;
    int32_t savedScale = g_ov.scale;

    /* ---- ESP boxes, in true pixels ---- */
    if (aowl_admin_toggle_get(g_ov_admin, AOWL_ADM_ESP) && g_ov_admin->inRaid) {
        /* HELD FRAME (task: the ESP FLICKER). Copy into the back slot; keep the
         * last good frame on a torn read so the boxes persist across every
         * Present between publisher commits instead of blanking for one frame.
         * A successful copy publishes the new frame by flipping the index; a
         * failure (return 0) leaves g_ovAdminSnapCur -- and thus what we draw --
         * pointing at the previous good frame. */
        int32_t nx = (g_ovAdminSnapCur < 0) ? 0 : ((g_ovAdminSnapCur + 1) & 1);
        if (aowl_admin_snapshot(g_ov_admin, &g_ovAdminSnap[nx]))
            g_ovAdminSnapCur = nx;
        if (g_ovAdminSnapCur >= 0) {
            AowlAdminShared* snap = &g_ovAdminSnap[g_ovAdminSnapCur];
            g_ov.scale = 1;
            for (int32_t i = 0; i < snap->count; i++) {
                AowlAdminEntity* e = &snap->ents[i];
                if (!(e->flags & AOWL_ADM_F_ONSCREEN)) continue;
                float h = e->bottom - e->top;
                if (h < 2.0f || h > (float)g_ov.bbH) continue;
                float w = h * 0.42f;
                float l = e->cx - w * 0.5f;
                uint32_t col = aowl_ov_admin_side_col(e->side);
                aowl_ov_frame_rect(l, e->top, w, h, 1.0f, col);
                /* Health bar down the left edge, when the mod could read it. */
                if (e->maxHealth > 0.0f && e->health >= 0.0f) {
                    float frac = e->health / e->maxHealth;
                    if (frac < 0.0f) frac = 0.0f;
                    if (frac > 1.0f) frac = 1.0f;
                    float bh = h * frac;
                    aowl_ov_rect(l - 4.0f, e->top, 2.0f, h, AOWL_RGBA(30, 30, 30, 200));
                    aowl_ov_rect(l - 4.0f, e->top + (h - bh), 2.0f, bh,
                                 AOWL_RGBA(80, 200, 110, 255));
                }
                /* Distance under the feet. */
                {
                    char db[24];
                    _snprintf(db, sizeof(db), "%dm", (int)e->distance);
                    db[sizeof(db) - 1] = 0;
                    aowl_ov_text(l, e->bottom + 2.0f, db, col);
                }
                if (e->name[0])
                    aowl_ov_text(l, e->top - (float)AOWL_OV_CH - 1.0f, e->name, col);
            }
        }
    } else {
        /* Not drawing ESP this Present (raid ended, or ESP toggled off while
         * the F6 menu keeps this append alive): drop the held frame so the
         * NEXT raid never shows this one's boxes for the Present or two before
         * its first fresh snapshot lands. */
        g_ovAdminSnapCur = -1;
    }

    /* ---- The F6 menu, at panel scale ---- */
    if (aowl_admin_menu_open(g_ov_admin)) {
        g_ov.scale = g_ov.scalePref > 0 ? g_ov.scalePref
               : (g_ov.bbH >= 2500) ? 3 : (g_ov.bbH >= 1300) ? 2 : 1;
        float rowH = (float)AOWL_OV_CH + 5.0f;
        float mw = 250.0f;
        float mx = 18.0f, my = 70.0f;
        mw = 430.0f;   /* wider again: each toggle row now carries its hotkey too */
        float mh = rowH * (float)(AOWL_ADM_ROW_TOTAL + 3) + 8.0f;
        int32_t sel = (int32_t)g_ov_admin->menuSel;
        aowl_ov_rect(mx, my, mw, mh, AOWL_OV_BG);
        aowl_ov_frame_rect(mx, my, mw, mh, 1.0f, AOWL_OV_EDGE);
        aowl_ov_text(mx + 8.0f, my + 6.0f, "ADMIN  (F6)", AOWL_OV_ACCENT);
        for (int32_t i = 0; i < AOWL_ADM_ROW_TOTAL; i++) {
            float ry = my + rowH * (float)(i + 1) + 6.0f;
            if (i == sel)
                aowl_ov_rect(mx + 2.0f, ry - 1.0f, mw - 4.0f, rowH, AOWL_OV_SELBG);
            uint32_t col = AOWL_OV_OFF;
            const char* st = "";
            char valbuf[AOWL_ADM_QUERY_LEN + 8];
            if (aowl_admin_row_is_toggle(i)) {
                if (!aowl_admin_capable(g_ov_admin, i)) { col = AOWL_OV_DIM; st = "n/a"; }
                else if (aowl_admin_toggle_get(g_ov_admin, i)) { col = AOWL_OV_ON; st = "ON"; }
                else { col = AOWL_OV_OFF; st = "off"; }
            } else if (i == AOWL_ADM_ROW_QUERY) {
                int32_t n = aowl_admin_spawn_query(g_ov_admin, valbuf,
                                                  (int32_t)sizeof(valbuf) - 2);
                /* A caret ONLY while this row has focus, so an empty query on
                 * an unfocused row reads as empty rather than as a stray bar. */
                if (i == sel) { valbuf[n] = '_'; valbuf[n + 1] = 0; }
                else if (n == 0) { valbuf[0] = '-'; valbuf[1] = 0; }
                col = AOWL_OV_TEXT; st = valbuf;
            } else if (i == AOWL_ADM_ROW_COUNT) {
                aowl_ov_fmt(valbuf, (int32_t)sizeof(valbuf), "%d",
                            aowl_admin_spawn_count(g_ov_admin));
                col = AOWL_OV_TEXT; st = valbuf;
            } else if (i == AOWL_ADM_ROW_COND) {
                aowl_ov_fmt(valbuf, (int32_t)sizeof(valbuf), "%d%%",
                            aowl_admin_spawn_condition(g_ov_admin));
                col = AOWL_OV_TEXT; st = valbuf;
            } else { /* AOWL_ADM_ROW_SPAWN */
                if (aowl_admin_spawn_busy(g_ov_admin)) { col = AOWL_OV_DIM; st = "busy"; }
                else { col = AOWL_OV_ACCENT; st = ">>"; }
            }
            aowl_ov_text(mx + 10.0f, ry + 2.0f, aowl_admin_row_name(i), AOWL_OV_TEXT);
            aowl_ov_text(mx + 148.0f, ry + 2.0f, st, col);
            /* The HOTKEY column. Only toggle rows have one. It shows the key
             * that is actually in the region, so what is drawn is the state
             * the poll will read -- not an echo of whatever was last typed. */
            if (aowl_admin_row_is_toggle(i)) {
                if (aowl_admin_hotkey_capturing(g_ov_admin) &&
                    (int32_t)g_ov_admin->hotkeyCapture == i) {
                    aowl_ov_text(mx + 210.0f, ry + 2.0f,
                                 "<press a key   Del=clear   Esc=cancel>",
                                 AOWL_OV_ACCENT);
                } else if (!aowl_admin_capable(g_ov_admin, i)) {
                    /* Deliberately NOT blank: blank reads as "no key yet",
                     * which invites the player to try to set one on an action
                     * whose write is not bound. */
                    aowl_ov_text(mx + 210.0f, ry + 2.0f, "[not bound]", AOWL_OV_DIM);
                } else {
                    const char* kn = aowl_admin_hotkey_name(g_ov_admin, i);
                    aowl_ov_text(mx + 210.0f, ry + 2.0f,
                                 (kn && kn[0]) ? kn : "[K to bind]",
                                 (kn && kn[0]) ? AOWL_OV_TEXT : AOWL_OV_DIM);
                }
            }
        }
        /* The last spawn result, verbatim. It is populated on refusal as well
         * as on success -- there is deliberately no "it worked" styling here,
         * because the only thing this HUD knows is the sentence the provider
         * sent back. */
        {
            const char* res = aowl_admin_spawn_result(g_ov_admin);
            const char* hkn = aowl_admin_hotkey_note_text(g_ov_admin);
            float ry = my + rowH * (float)(AOWL_ADM_ROW_TOTAL + 1) + 8.0f;
            if (res && res[0]) {
                aowl_ov_text(mx + 10.0f, ry, res, AOWL_OV_DIM);
                ry += (float)AOWL_OV_CH + 2.0f;
            }
            /* Why the last rebind was REFUSED, verbatim. A refusal nobody can
             * see is the same as a silent no-op, which is the failure this
             * whole feature exists not to be. */
            if (hkn && hkn[0])
                aowl_ov_text(mx + 10.0f, ry, hkn, AOWL_OV_ACCENT);
        }
    }

    g_ov.scale = savedScale;
    g_ov.needUpload = 1;   /* the vertex buffer changed, so it must re-upload   */
}

/* ------------------------------------------------------------------ *
 * The launch hint
 *
 * "Press F12 for Mod Settings", top-right, once per launch, gone in a few
 * seconds. Drawn by this Present hook -- the same one the panel uses -- so it
 * needs no detour of its own, touches no managed object, and allocates
 * nothing: both strings are literals and the per-frame work while it is up is
 * a dozen quads.
 *
 * WHEN IT APPEARS, and why:
 *
 *   * NOT at process start. The client takes over a minute to reach a menu and
 *     a hint about a panel that cannot yet show anything is a lie. It arms on
 *     the first frame after the BACKEND HAS ANSWERED AT LEAST ONCE
 *     (`everOk`) -- which is the same condition that decides whether F12
 *     shows a populated panel or an empty one, so the hint is true exactly
 *     when it appears. This is a check that CAN fail: with the backend down,
 *     no hint is shown, and the host log says so.
 *   * ...and not after AOWL_OV_HINT_LATEST of process life. Past that the
 *     player is in a raid or deep in a menu and a toast is an intrusion. This
 *     is the "must not appear during a raid" guarantee, and it is a clock,
 *     not a guess about game state the overlay cannot see.
 *   * ONCE. `hintState` goes to 2 and never comes back, so backing out of a
 *     screen does not re-show it.
 *   * NEVER when the setting is off. `hintEnabled` is the value READ from
 *     `aowl.uihub`, falling back to the remembered one -- never to this file`s
 *     default.
 *
 * It steals no input: nothing here reads `clickDown`, `mouseHeld` or the key
 * ring, and it draws no hit-tested rectangle, so a click that lands on it goes
 * to the game exactly as if it were not there.
 * ------------------------------------------------------------------ */
#define AOWL_OV_HINT_HOLD    6000u   /* fully visible, ms */
#define AOWL_OV_HINT_FADE    1200u   /* then fades out over this */
#define AOWL_OV_HINT_LATEST 600000u  /* never arms later than this into a run */

static DWORD g_ov_hintBoot = 0;

/* 0..255, or 0 when the toast should not be drawn at all. Advances the state
 * machine; called once per present. */
static int32_t aowl_ov_hint_alpha(void) {
    DWORD now = GetTickCount();
    DWORD age;
    if (!g_ov_hintBoot) g_ov_hintBoot = now ? now : 1;
    if (g_ov.hintState >= 2) return 0;
    if (!g_ov.hintEnabled) {
        if (g_ov.hintState != 2) {
            g_ov.hintState = 2;
            aowl_ov_note("launch hint suppressed: launchHint is off (value as "
                         "read, not a default)");
        }
        return 0;
    }
    if (g_ov.hintState == 0) {
        if (now - g_ov_hintBoot > AOWL_OV_HINT_LATEST) {
            g_ov.hintState = 2;
            aowl_ov_note("launch hint not shown: the backend did not answer "
                         "inside the arming window");
            return 0;
        }
        if (!g_ov.everOk) return 0;      /* the panel would be empty; wait */
        g_ov.hintState = 1;
        g_ov.hintAt = now ? now : 1;
        aowl_ov_note("launch hint shown");
    }
    age = now - g_ov.hintAt;
    if (age < AOWL_OV_HINT_HOLD) return 255;
    /* With animation off the toast CUTS rather than fades. It is the same
     * total time on screen either way -- turning animation off must not also
     * silently change how long the message is readable for. */
    if (!g_ov.animate) {
        if (age < AOWL_OV_HINT_HOLD + AOWL_OV_HINT_FADE) return 255;
    } else if (age < AOWL_OV_HINT_HOLD + AOWL_OV_HINT_FADE) {
        DWORD f = age - AOWL_OV_HINT_HOLD;
        return (int32_t)(255u - (f * 255u) / AOWL_OV_HINT_FADE);
    }
    g_ov.hintState = 2;
    g_ov.hintGoneAt = now ? now : 1;
    aowl_ov_note("launch hint gone");
    return 0;
}

/* Vertices for the toast, appended to whatever else this frame is drawing --
 * the same way the admin HUD and the shared region append theirs. */
static void aowl_ov_hint_append(int32_t a) {
    static const char* L1 = " Press F12 for Mod Settings ";
    static const char* L2 = " turn this off in Settings > UI hub ";
    float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float availW = (g_ov.bbW ? (float)g_ov.bbW : 1280.0f) / k;
    float w = (float)(strlen(L2) + 2) * AOWL_OV_CW;
    float hgt = (float)(AOWL_OV_LINE_H * 2 + 12);
    float bx = availW - w - 24.0f, by = 24.0f;
    uint32_t A = (uint32_t)(a & 0xFF) << 24;
    if (bx < 8.0f) bx = 8.0f;
    aowl_ov_rect(bx, by, w, hgt,
                 (AOWL_OV_TITLEBG & 0x00FFFFFFu) |
                 ((uint32_t)((a * 235) / 255) << 24));
    aowl_ov_frame_rect(bx, by, w, hgt, 1.0f, (AOWL_OV_EDGE & 0x00FFFFFFu) | A);
    aowl_ov_text(bx + 8.0f, by + 6.0f, L1, (AOWL_OV_TEXT & 0x00FFFFFFu) | A);
    /* "fine/smaller print": this font has one size, so the second line is made
     * quieter with colour instead -- FAINT against TEXT is the same difference
     * in emphasis the rest of the panel uses. */
    aowl_ov_text(bx + 8.0f, by + 6.0f + (float)AOWL_OV_LINE_H, L2,
                 (AOWL_OV_FAINT & 0x00FFFFFFu) | A);
    g_ov.hintShownFrames++;
}

/* For the tests and for `aowl_ov_status`: 0 = never shown, 1 = up now,
 * 2 = shown and gone. Reading it does not advance it. */
static int32_t aowl_ov_hint_state(void) { return g_ov.hintState; }

/* WHERE THE PANEL ACTUALLY IS, in panel units, as of the last built frame.
 *
 * Exists because `tests/overlayhost` was re-deriving it from
 * AOWL_OV_PANEL_W and the back-buffer width -- a second, independent
 * computation of the same thing, which is the shape that breaks silently the
 * moment the first one changes. It did: adding drag/resize changed the width
 * clamp by 40 pixels and the test`s synthetic click landed in the next column
 * along, reporting "the button geometry and the hit test have drifted apart"
 * about a button that was fine. Ask, do not re-derive. */
static void aowl_ov_panel_rect(float* px, float* py, float* pw, float* ph) {
    float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float availW = (g_ov.bbW ? (float)g_ov.bbW : 1280.0f) / k;
    float availH = (g_ov.bbH ? (float)g_ov.bbH : 720.0f) / k;
    if (g_ov.panMax) {
        if (px) *px = 0.0f;
        if (py) *py = 0.0f;
        if (pw) *pw = availW;
        if (ph) *ph = availH;
        return;
    }
    {
        float x = g_ov.panX, y = g_ov.panY, w = g_ov.panW, h = g_ov.panH;
        if (w < 1.0f) { x = (float)AOWL_OV_PANEL_X; y = (float)AOWL_OV_PANEL_Y;
                        w = (float)AOWL_OV_PANEL_W; h = (float)AOWL_OV_PANEL_H; }
        if (w > availW) w = availW;
        if (w < 480.0f) w = 480.0f;
        if (h > availH) h = availH;
        if (h < 220.0f) h = 220.0f;
        if (y + h > availH) h = availH - y;
        if (h < 220.0f) h = 220.0f;
        if (x >= 0.0f && x + w > availW) w = availW - x;
        if (w < 480.0f) w = 480.0f;
        if (px) *px = x;
        if (py) *py = y;
        if (pw) *pw = w;
        if (ph) *ph = h;
    }
}
static int32_t aowl_ov_hint_frames(void) { return g_ov.hintShownFrames; }

static HRESULT STDMETHODCALLTYPE aowl_ov_present(IDXGISwapChain* sc, UINT sync,
                                                 UINT flags) {
    AowlPresentFn orig = (AowlPresentFn)g_ov.presentOrig;

    /* DXGI_PRESENT_TEST does not present anything; it is a "would this work"
     * probe that games call every frame when occluded. Drawing on it wastes a
     * frame's work and, worse, some drivers pass a back buffer that is not
     * current. Pass it straight through. */
    if (g_ov.broken || (flags & DXGI_PRESENT_TEST))
        return orig(sc, sync, flags);

    /* One draw at a time. Present is not reentrant in practice, but a driver
     * or another overlay in the process calling it from inside our hook would
     * otherwise reenter the shared vertex scratch. */
    if (InterlockedCompareExchange(&g_ov.inDraw, 1, 0) == 0) {
        g_ov.frames++;
        /* Grade the finished frame first, so the overlay's UI (drawn below)
         * composites crisp on top of the graded image. Runs every frame, even
         * when the panel is hidden -- the post-process is not the panel. It
         * acquires the game device from `sc` itself and saves/restores the
         * pipeline state it touches, so the overlay's own bind/draw below still
         * sees the game's state. */
        if (g_ov_prePresent)
            ((void (*)(IDXGISwapChain*))g_ov_prePresent)(sc);
        /* Opened again. `avgNs`/`maxNs` are deliberately *not* cleared here --
         * see the note on `aowl_ov_frame_ns` -- so this counts what this
         * opening has contributed, which is what says whether the figure on
         * the title bar is this session's or the last one's. The edge is
         * detected here rather than in `aowl_ov_set_visible` because the
         * toggle key and ESC write `visible` directly, and a counter that only
         * the API path reset would be right for the one caller nobody uses. */
        if (g_ov.visible && !g_ov.wasVisible) g_ov.openDrawn = 0;
        /* CLOSING THE PANEL SENDS WHAT IS HELD. `aowl_ov_s_flush_tick` only
         * runs from the settings draw, so a value changed and then F12`d away
         * inside the quiet period would have sat in the slot until the panel
         * was next opened -- a write that looks applied on screen and is not on
         * disk, which is the worst outcome this whole slot could produce. */
        if (!g_ov.visible && g_ov.wasVisible) aowl_ov_s_flush_now();
        /* CLOSING THE PANEL ALSO STOPS THE LOG TAIL. `logWant` is set in
         * `aowl_ov_build`, and `aowl_ov_build` is not called at all while the
         * panel is shut -- so a panel closed while the LOGS view was up would
         * have left the flag at 1 and the worker opening two files every
         * 400 ms for the rest of the session, invisibly. A flag whose only
         * writer stops running is a flag that gets stuck on. */
        if (!g_ov.visible) InterlockedExchange(&g_ov.logWant, 0);
        g_ov.wasVisible = g_ov.visible;
        int32_t adminOn = aowl_ov_admin_active();
        /* Say which panels are open, EVERY frame and including "none". The host
         * frees and restores the cursor off the back of this; see
         * `aowl_ov_publish_cursor_panels`. This is unconditional -- it is not
         * inside the `aowl_ov_bind(sc) && (visible || ...)` block below -- so
         * that the frame a panel CLOSES still publishes an empty mask promptly
         * rather than relying on the staleness timeout to notice. */
        aowl_ov_publish_cursor_panels();
        /* The shared region draws whenever it has published anything, exactly
         * as the admin HUD draws whenever it is live -- otherwise a mod's
         * markers would appear only while the manager panel happened to be
         * open, which reads to a player as "the mod is broken". */
        int32_t regionOn = 0;
        {
            const AowlRegionCmd* rcPeek = 0;
            regionOn = aowl_region_commands(&rcPeek) > 0 ? 1 : 0;
        }
        /* Tell the mod the resolution it must project to, every frame the swap
         * chain is bound, so its screen coordinates match this back buffer even
         * across a resize. */
        if (g_ov_admin && aowl_ov_bind(sc))
            aowl_admin_set_screen(g_ov_admin, (int32_t)g_ov.bbW, (int32_t)g_ov.bbH);
        int32_t hintA = aowl_ov_hint_alpha();
        if (aowl_ov_bind(sc) && (g_ov.visible || adminOn || regionOn || hintA)) {
            /* What one frame of this costs, measured rather than asserted. The
             * overlay is drawn inside the present loop of a game people play
             * competitively, so "it is cheap" is a claim that has to have a
             * number attached and the number has to come from the machine it is
             * running on. Three QPC reads -- one each side of the build and
             * one after the draw -- is about sixty nanoseconds and it buys a
             * figure the player can see on the title bar, and the build/draw
             * split behind it. */
            LARGE_INTEGER t0, tb, t1;
            QueryPerformanceCounter(&t0);
            /* The manager panel builds only when it is visible. The admin HUD
             * is independent: it draws when the F6 menu is open or ESP is live,
             * whether or not the panel is up. When both are on, the geometry
             * cache is defeated (drawSig = 0) so the per-frame ESP is not held
             * back by the panel's "nothing changed" fast path. */
            if (g_ov.visible) {
                if (adminOn || regionOn) g_ov.drawSig = 0;
                aowl_ov_build();
            } else {
                g_ov.vtxCount = 0;
                g_ov.spanN = 0;
                g_ov.scale = g_ov.scalePref > 0 ? g_ov.scalePref
               : (g_ov.bbH >= 2500) ? 3 : (g_ov.bbH >= 1300) ? 2 : 1;
                g_ov.needUpload = 1;
            }
            if (adminOn) aowl_ov_admin_append();
            /* And every participant of the SHARED region, generically. */
            if (regionOn) aowl_ov_region_append();
            /* The launch hint, last, so it is on top of everything. While it is
             * up the geometry cache is defeated -- it fades, so its vertices
             * genuinely differ every frame -- and it stops costing anything the
             * moment `hintA` reaches 0. */
            if (hintA) { g_ov.drawSig = 0; aowl_ov_hint_append(hintA); }
            QueryPerformanceCounter(&tb);
            aowl_ov_draw(sc);
            QueryPerformanceCounter(&t1);
            if (g_ov.vtxCount > g_ov.maxVtx) g_ov.maxVtx = g_ov.vtxCount;
            if (g_ov.qpcFreq.QuadPart > 0) {
                LONGLONG ns = ((t1.QuadPart - t0.QuadPart) * 1000000000LL)
                              / g_ov.qpcFreq.QuadPart;
                LONG n = (LONG)(ns > 2000000000LL ? 2000000000LL : ns);
                InterlockedExchange(&g_ov.lastNs, n);
                /* The first few frames after the panel opens are not
                 * representative and are dropped from both figures: the vertex
                 * buffer's first `Map` after a `DISCARD` allocates, the font
                 * texture is cold in the GPU's cache, and on a WARP device the
                 * first draw compiles. Counting them would put a number in the
                 * legend that is twenty times the steady state and is a fact
                 * about start-up rather than about the overlay.
                 *
                 * `drawn` is the render thread's own counter, so no atomics. */
                g_ov.drawn++;
                g_ov.openDrawn++;
                if (g_ov.drawn > 8) {
                    /* An EWMA at 1/32, which settles in about a hundred frames
                     * -- long enough not to flicker, short enough that a change
                     * in what is on screen shows up while you are still looking
                     * at it. `max` is never lowered: the worst frame is the one
                     * that stutters, and an average hides it by construction. */
                    InterlockedExchange(&g_ov.avgNs,
                                        g_ov.avgNs ? g_ov.avgNs + (n - g_ov.avgNs) / 32 : n);
                    if (n > g_ov.maxNs) InterlockedExchange(&g_ov.maxNs, n);
                    /* Split, because the two halves are fixed by different
                     * things and only one of them is ours to improve. `build`
                     * is laying out text into a vertex array -- pure CPU, and
                     * proportional to how much is on screen. The rest is
                     * `aowl_ov_draw`: two `Map(WRITE_DISCARD)`s, one `Draw`,
                     * and the fifty-odd D3D11 `*Get*`/`*Set*` calls that save
                     * and restore the game's pipeline state. That second half
                     * is the price of drawing inside somebody else's `Present`
                     * and it does not get smaller by drawing less. */
                    {
                        LONG b = (LONG)(((tb.QuadPart - t0.QuadPart) * 1000000000LL)
                                        / g_ov.qpcFreq.QuadPart);
                        InterlockedExchange(&g_ov.avgBuildNs,
                            g_ov.avgBuildNs ? g_ov.avgBuildNs + (b - g_ov.avgBuildNs) / 32 : b);
                    }
                }
            }
        }
        InterlockedExchange(&g_ov.inDraw, 0);
    }
    return orig(sc, sync, flags);
}

static HRESULT STDMETHODCALLTYPE aowl_ov_resize(IDXGISwapChain* sc, UINT count,
                                                UINT w, UINT h, DXGI_FORMAT fmt,
                                                UINT flags) {
    AowlResizeFn orig = (AowlResizeFn)g_ov.resizeOrig;
    /* The single most common way an overlay breaks a game: ResizeBuffers fails
     * with DXGI_ERROR_INVALID_CALL if anything still holds a reference to a
     * back buffer, and our RTV does. Release it first; the next Present
     * recreates it against the new buffer. Note this must happen even when
     * `broken` is set, because the RTV may have been created before the
     * failure. */
    if (g_ov.swap == sc) aowl_ov_release_targets();
    /* The post-process pins the back buffer too (its RTV + scene copy); it must
     * drop those before the resize for the same DXGI_ERROR_INVALID_CALL reason. */
    if (g_ov_preResize)
        ((void (*)(IDXGISwapChain*))g_ov_preResize)(sc);
    HRESULT hr = orig(sc, count, w, h, fmt, flags);
    return hr;
}

/* ------------------------------------------------------------------ *
 * Vtable capture
 * ------------------------------------------------------------------ */

typedef HRESULT (WINAPI *AowlD3D11CreateFn)(IDXGIAdapter*, D3D_DRIVER_TYPE, HMODULE,
                                            UINT, const D3D_FEATURE_LEVEL*, UINT,
                                            UINT, const DXGI_SWAP_CHAIN_DESC*,
                                            IDXGISwapChain**, ID3D11Device**,
                                            D3D_FEATURE_LEVEL*, ID3D11DeviceContext**);

/* Present is vtable slot 8 and ResizeBuffers is slot 13, counted as:
 *   IUnknown             0..2   QueryInterface, AddRef, Release
 *   IDXGIObject          3..6   Set/SetInterface/GetPrivateData, GetParent
 *   IDXGIDeviceSubObject 7      GetDevice
 *   IDXGISwapChain       8..    Present, GetBuffer, SetFullscreenState,
 *                               GetFullscreenState, GetDesc, ResizeBuffers, ...
 * These indices are fixed by the interface definition, not by a build of DXGI,
 * so they are stable in a way a byte pattern is not. */
#define AOWL_OV_SLOT_PRESENT 8
#define AOWL_OV_SLOT_RESIZE  13

static int32_t aowl_ov_capture_vtable(void** outPresent, void** outResize) {
    HMODULE d3d11 = LoadLibraryA("d3d11.dll");
    if (!d3d11) { aowl_ov_fail("d3d11.dll is not loaded"); return 0; }
    AowlD3D11CreateFn create =
        (AowlD3D11CreateFn)(void*)GetProcAddress(d3d11, "D3D11CreateDeviceAndSwapChain");
    if (!create) { aowl_ov_fail("D3D11CreateDeviceAndSwapChain not found"); return 0; }

    /* A message-only window would be simpler but cannot host a swap chain;
     * DXGI refuses HWND_MESSAGE children. So: a real window, 1x1, never shown,
     * destroyed before this function returns. */
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"aowlspt_ov_probe";
    RegisterClassExW(&wc);
    HWND hw = CreateWindowExW(0, L"aowlspt_ov_probe", L"", WS_OVERLAPPEDWINDOW,
                              0, 0, 1, 1, NULL, NULL, wc.hInstance, NULL);
    if (!hw) {
        UnregisterClassW(L"aowlspt_ov_probe", wc.hInstance);
        aowl_ov_fail("could not create the probe window");
        return 0;
    }

    DXGI_SWAP_CHAIN_DESC sd;
    memset(&sd, 0, sizeof(sd));
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 1;
    sd.BufferDesc.Height = 1;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain* sc = NULL;
    ID3D11Device* dev = NULL;
    ID3D11DeviceContext* ctx = NULL;
    D3D_FEATURE_LEVEL got;
    /* HARDWARE first, then WARP. The vtable is the same either way -- it comes
     * from dxgi.dll, not from the driver -- so falling back to the software
     * rasteriser costs nothing and makes this work on a machine with no GPU,
     * which is exactly the machine the test host runs on in CI. */
    HRESULT hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                        D3D11_SDK_VERSION, &sd, &sc, &dev, &got, &ctx);
    if (FAILED(hr))
        hr = create(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, NULL, 0,
                    D3D11_SDK_VERSION, &sd, &sc, &dev, &got, &ctx);

    int32_t ok = 0;
    if (SUCCEEDED(hr) && sc) {
        void** vt = *(void***)sc;
        *outPresent = vt[AOWL_OV_SLOT_PRESENT];
        *outResize  = vt[AOWL_OV_SLOT_RESIZE];
        ok = 1;
    } else {
        aowl_ov_fail("could not create the probe swap chain");
    }

    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (dev) ID3D11Device_Release(dev);
    if (sc)  IDXGISwapChain_Release(sc);
    DestroyWindow(hw);
    UnregisterClassW(L"aowlspt_ov_probe", wc.hInstance);
    return ok;
}

/* ================================================================== *
 * Lifecycle
 * ================================================================== */

/* Must not be called from DllMain: it creates a window, a device and a thread,
 * all three of which deadlock under the loader lock. The client host calls it
 * from the boot thread `aowlspt_hostboot.h` starts, which is the right place.
 *
 * `toggleVk` is a virtual key code (VK_INSERT = 0x2D by default).
 * `backendPort` is the aowlspt backend's port; 0 disables the HTTP client and
 * leaves the panel read-only.
 *
 * Returns 1 on success, 0 on failure -- and on failure `aowl_ov_status` says
 * why, in a form meant to be logged verbatim. A 0 means *the overlay cannot
 * draw*; when `backendPort` is non-zero the worker thread is running either
 * way, so `aowl_ov_sync_start` is still worth calling. */
static int32_t aowl_ov_start(int32_t toggleVk, int32_t backendPort) {
    if (InterlockedCompareExchange(&g_ov.started, 1, 0) != 0) return 1;

    /* `aowl_ov_stop` latches `broken` on the way out so the detours become
     * pass-throughs while they are still installed; a later start has to clear
     * it or it would come up already dead. */
    InterlockedExchange(&g_ov.broken, 0);
    InitializeCriticalSection(&g_ov.cs);
    /* Map the admin/cheat HUD's shared region. Failure is not fatal: a NULL
     * pointer makes every admin draw a no-op, so a host with no admin mod loaded
     * simply has an overlay with no HUD. */
    if (!g_ov_admin) g_ov_admin = aowl_admin_map();
    g_ov.toggleVk = toggleVk ? toggleVk : VK_INSERT;
    g_ov.backendPort = backendPort;
    QueryPerformanceFrequency(&g_ov.qpcFreq);
    g_ov.view = AOWL_VIEW_MODS;
    g_ov.filter = AOWL_FILTER_ALL;
    /* The settings screen starts closed, on no page, with nothing being edited.
     * -1 rather than 0 for the edit cursors: 0 is a valid row. */
    g_ov.settings = 0;
    g_ov.selPage = 0; g_ov.topPage = 0;
    g_ov.selItem = 0; g_ov.topItem = 0;
    g_ov.editItem = -1;
    g_ov.dragItem = -1;
    /* The write slot starts empty, and `showUnimpl` starts OFF -- the house
     * rule that a new surface ships in the state a beta tester should see. */
    g_ov.pendArm = 0; g_ov.pendAt = 0; g_ov.writeCount = 0;
    g_ov.pendPage[0] = 0; g_ov.pendKey[0] = 0; g_ov.pendVal[0] = 0;
    g_ov.showUnimpl = 0; g_ov.hiddenCount = 0; g_ov.sHiddenCount = 0;
    g_ov.selCat = -1;      /* -1 is "the whole page", the only sane start */
    g_ov.search[0] = 0; g_ov.searchFocus = 0;
    g_ov.filtCount = 0; g_ov.filtStamp = 0;
    /* The logs screen opens showing EVERYTHING, following the newest line, and
     * with its search box unfocused -- see the input-model note in
     * `aowl_ov_keys`. `logFiltStamp` of 0 means "nothing has been computed",
     * which forces the first refilter. */
    g_ov.logSrcFilt = AOWL_LOGSRC_ALL;
    g_ov.logLvlFilt = AOWL_LOGF_ALL;
    g_ov.logFacetFilt = AOWL_LOG_FACET_ALL;
    g_ov.logSearch[0] = 0; g_ov.logSearchFocus = 0;
    g_ov.logFollow = 1;
    g_ov.logFiltN = 0; g_ov.logFiltStamp = 0;
    g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0; g_ov.logSerial = 0;
    g_ov.logFacetN = 0; g_ov.logFacetOver = 0;
    g_ov.logPathsDone = 0;
    {
        int32_t li;
        for (li = 0; li < AOWL_LOG_SRCS; li++) {
            g_ov.logOff[li] = 0; g_ov.logOpened[li] = 0; g_ov.logFail[li] = 0;
            g_ov.logOff2[li] = 0; g_ov.logLines[li] = 0; g_ov.logCarryN[li] = 0;
            g_ov.logWhy[li][0] = 0; g_ov.logPath[li][0] = 0;
        }
    }
    InterlockedExchange(&g_ov.logWant, 0);
    g_ov.dragWin = 0; g_ov.dragGrip = 0;
    /* Every page starts OPEN. A tree that boots collapsed shows the player a
     * list of names and no settings, which is indistinguishable from a page
     * that failed to load -- and the panel has spent enough of its life being
     * indistinguishable from broken. Collapsing is then something they choose,
     * and `navOpen` (the per-node half) starts empty, so only the branch the
     * selection is in is expanded. */
    {
        int32_t k;
        for (k = 0; k < AOWL_OV_MAX_SPAGES; k++) g_ov.pageOpen[k] = 1;
    }
    memset(g_ov.navOpen, 0, sizeof(g_ov.navOpen));
    g_ov.navOpenFor[0] = 0;
    g_ov.hintState = 0; g_ov.hintFetched = 0; g_ov.hintShownFrames = 0;
    /* Where the window is, how solid it is, and whether the launch hint is
     * wanted -- read from disk BEFORE the first present, so the panel never
     * flashes at a default position on its way to the remembered one. The
     * value it read is in `status`. */
    /* Themes BEFORE prefs: the prefs name a theme by NAME, and applying a name
     * against an empty table would silently land on the compiled default while
     * reporting the name the player chose. */
    aowl_ov_themes_load();
    aowl_ov_prefs_load();
    /* THE ROUND TRIP, asserted on the FINISHED state rather than on the read:
     * the theme that is actually live after start-up, not the name the prefs
     * file happened to contain. A remembered name that no longer names a theme
     * (the file was deleted, renamed, or never parsed) silently left the
     * palette on Dark while the picker went on displaying the missing name --
     * the panel claiming a selection it does not have. */
    aowl_ov_theme_apply(g_ov.themeName);
    if (aowl_ov_theme_find(g_ov.themeName) < 0) {
        char tw[160];
        aowl_ov_fmt(tw, (int32_t)sizeof(tw),
                    "overlay theme: %s is not installed, so the palette fell "
                    "back to Dark", g_ov.themeName);
        aowl_ov_note(tw);
        aowl_ov_copy(g_ov.themeName, (int32_t)sizeof(g_ov.themeName), "Dark");
    }
    /* THE ROUND TRIP, said out loud every launch, naming the file, the value
     * the file holds, and the value that is live AFTER every default, fallback
     * and re-apply above has had its turn. Three outcomes, never two: an empty
     * disk value is INCONCLUSIVE ("nothing has ever been saved"), which is what
     * a broken write path looks like and is exactly what this line exists to
     * stop being invisible for months. Prints the PATH too, because the whole
     * defect was that the path named a directory that could not exist. */
    {
        char rt[300];
        const char* verdict =
            (!g_ovPrefsDiskTheme[0]) ? "INCONCLUSIVE (no theme saved yet)"
            : (!strcmp(g_ovPrefsDiskTheme, g_ov.themeName)) ? "PASS"
            : "FAIL";
        aowl_ov_fmt(rt, (int32_t)sizeof(rt),
                    "overlay prefs round-trip: key=theme onDisk=%s inEffect=%s "
                    "file=%s -- %s",
                    g_ovPrefsDiskTheme[0] ? g_ovPrefsDiskTheme : "(none)",
                    g_ov.themeName,
                    g_ov.prefsPath[0] ? g_ov.prefsPath : "(no path)",
                    verdict);
        aowl_ov_note(rt);
    }
    g_ov.viewLo = 0; g_ov.viewHi = 0;
    g_ov.capturing = 0;
    g_ov.curPage[0] = 0;
    g_ov.itemsPage[0] = 0;
    g_ov.sItemsPage[0] = 0;
    g_ov.editBuf[0] = 0;
    g_ov.pageCount = 0;
    g_ov.sptPageCount = 0;
    g_ov.sptGot = 0;
    g_ov.idxModCount = 0;
    g_ov.idxGot = 0;
    g_ov.idxWhy[0] = 0;
    g_ov.catCount = 0;
    g_ov.itemsWhy[0] = 0;
    g_ov.writeWhy[0] = 0;
    g_ov.sWriteWhy[0] = 0;
    g_ov.itemCount = 0;
    g_ov.mouseHeld = 0;
    /* -1, not 0: zero is a sequence number the client host really sends on its
     * first report, and a panel that started at zero would read "seq 0" as an
     * answer before anybody had spoken. */
    g_ov.clientSeq = -1;
    g_ov.sClientSeq = -1;
    g_ov.scale = 1;
    g_ov.keyHead = 0;
    g_ov.keyTail = 0;
    g_ov.snapSerial = -1;   /* so the first frame takes a snapshot */
    g_ov.dataSerial = 0;
    g_ov.lastNs = 0;
    g_ov.avgNs = 0;
    g_ov.maxNs = 0;
    g_ov.avgBuildNs = 0;
    g_ov.drawn = 0;
    g_ov.openDrawn = 0;
    g_ov.wasVisible = 0;
    g_ov.drawSig = 0;
    g_ov.needUpload = 1;
    g_ov.builds = 0;
    g_ov.dispTick = 0;
    g_ov.sigBbW = 0;
    g_ov.sigBbH = 0;
    g_ov.maxVtx = 0;
    g_ov.vtxDropped = 0;
    for (int32_t i = 0; i < AOWL_VIEW_COUNT; i++) { g_ov.sel[i] = 0; g_ov.top[i] = 0; }
    aowl_ov_note("starting");

    /* The backend client comes up before the renderer, and stays up if the
     * renderer does not.
     *
     * It used to be the last thing `aowl_ov_start` did, which made it a
     * dependant of the swap-chain capture: no vtable, no worker. That was fine
     * while the worker only fed a panel nobody could see anyway. It is not fine
     * now that the same thread carries the mod-sync feed -- whether the client
     * host obeys the server's mod selection would depend on whether a D3D11
     * device could be created, and the two have nothing to do with each other.
     * A host that cannot draw must still be able to load and unload what the
     * player asked for. */
    if (backendPort > 0) {
        g_ov.workerRun = 1;
        g_ov.worker = CreateThread(NULL, 0, aowl_ov_worker, NULL, 0, NULL);
    }

    void* present = NULL;
    void* resize = NULL;
    if (!aowl_ov_capture_vtable(&present, &resize)) return 0;

    g_ov.presentHook = aowl_hook_new();
    g_ov.resizeHook = aowl_hook_new();
    if (!g_ov.presentHook || !g_ov.resizeHook) {
        aowl_ov_fail("out of memory allocating hook records");
        return 0;
    }

    /* `aowl_hook_install` rather than `aowl_hook_attach`: attach allocates a
     * slot from the fixed pool of assembly thunks that `AowlHostApi.patch`
     * hands to mods, and those thunks exist to recover arguments for a hook
     * whose signature is not known at compile time. Ours is known -- it is
     * `HRESULT(IDXGISwapChain*, UINT, UINT)` -- so the detour can be a plain C
     * function and the pool stays intact for mods. */
    int32_t rc = aowl_hook_install(g_ov.presentHook, present, (void*)aowl_ov_present);
    if (rc != 0) {
        char msg[96];
        aowl_ov_fmt(msg, (int32_t)sizeof(msg),
                    "could not hook Present (detour error %d)", rc);
        aowl_ov_fail(msg);
        return 0;
    }
    g_ov.presentOrig = aowl_hook_trampoline(g_ov.presentHook);

    rc = aowl_hook_install(g_ov.resizeHook, resize, (void*)aowl_ov_resize);
    if (rc != 0) {
        /* Present alone is still a working overlay everywhere except across a
         * resolution change, so this is a degraded mode rather than a failure
         * -- but without it, a resize would fail in the game with
         * DXGI_ERROR_INVALID_CALL because our RTV pins the back buffer. That
         * is not acceptable, so the Present hook comes back out too. */
        aowl_hook_remove(g_ov.presentHook);
        char msg[96];
        aowl_ov_fmt(msg, (int32_t)sizeof(msg),
                    "could not hook ResizeBuffers (detour error %d)", rc);
        aowl_ov_fail(msg);
        return 0;
    }
    g_ov.resizeOrig = aowl_hook_trampoline(g_ov.resizeHook);

    aowl_ov_note("hooked; waiting for the first frame");
    return 1;
}

/* Unhooking a Present hook while the render thread might be inside it is the
 * hazard here, and there is no way to be certain it is not. The sequence below
 * makes the window as small as it can be: stop drawing first, let a few frames
 * go by, then remove the detours. Anything that survives that is a thread
 * suspended by a debugger inside our detour, which nothing can fix.
 *
 * In practice the client host does not call this -- the overlay lives for the
 * life of the process -- and it exists for the test host, which does. */
static void aowl_ov_stop(void) {
    if (!g_ov.started) return;
    InterlockedExchange(&g_ov.visible, 0);
    InterlockedExchange(&g_ov.broken, 1);   /* both detours become pass-through */

    if (g_ov.worker) {
        g_ov.workerRun = 0;
        WaitForSingleObject(g_ov.worker, 2000);
        CloseHandle(g_ov.worker);
        g_ov.worker = NULL;
    }
    /* After the worker has stopped, so nothing is inside a request when its
     * session goes away. */
    if (g_whSession && g_wh.close) { g_wh.close(g_whSession); g_whSession = NULL; }

    Sleep(120);   /* ~7 frames at 60 Hz; the render thread leaves the detour */

    if (g_ov.hwnd && g_ov.oldProc) {
        SetWindowLongPtrW(g_ov.hwnd, GWLP_WNDPROC, (LONG_PTR)g_ov.oldProc);
        g_ov.oldProc = NULL;
        g_ov.hwnd = NULL;
    }
    if (g_ov.presentHook) {
        aowl_hook_remove(g_ov.presentHook);
        aowl_hook_free(g_ov.presentHook);
        g_ov.presentHook = NULL;
    }
    if (g_ov.resizeHook) {
        aowl_hook_remove(g_ov.resizeHook);
        aowl_hook_free(g_ov.resizeHook);
        g_ov.resizeHook = NULL;
    }
    aowl_ov_release_all();
    DeleteCriticalSection(&g_ov.cs);
    InterlockedExchange(&g_ov.started, 0);
}

#endif /* AOWLSPT_OVERLAY_H */
