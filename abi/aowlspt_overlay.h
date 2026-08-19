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
 *   GS/HS/DS: shader only — see below
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
 *                   blocking call in this file.
 *
 * Everything shared between them is the `AowlOvMod` table and the command
 * queue, both under `g_ov.cs`.
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
#include <stdarg.h>

#include "aowlspt_detour.h"

/* ================================================================== *
 * Public surface
 * ================================================================== */

#define AOWL_OV_MAX_MODS     64
#define AOWL_OV_MAX_CMDS     32
#define AOWL_OV_MAX_LISTS    16
#define AOWL_OV_MAX_ENTRIES 160   /* list entries, flattened across all lists */
#define AOWL_OV_MAX_ISSUES   24   /* registry problems + excluded decisions   */
#define AOWL_OV_MAX_RESULTS  40   /* per-mod outcomes from one apply/toggle   */
#define AOWL_OV_KEYS         32   /* the wndproc -> render thread key ring    */

/* The mod-sync feed's buffer. It holds one whole response body and nothing is
 * acted on unless the body is whole, so the size is the ceiling on how many
 * mods the backend can describe -- about two hundred rows at seventy bytes
 * each. A body that does not fit is truncated by `aowl_ov_http`, loses its
 * terminating key, and is rejected by the reader rather than half-applied. */
#define AOWL_OV_SYNC_MAX 16384

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

/* Called on the *worker* thread after a toggle has been accepted, so the host
 * can react without polling. Optional; may be left NULL. */
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
 * render thread, and they cost one QPC pair per frame to keep.
 *
 * `avg` is an exponential moving average over roughly the last hundred frames;
 * `max` is the worst single frame since the overlay started, which is the one
 * that shows up as a stutter. Both are 0 while the panel is closed -- a hidden
 * panel is one `if` in the hook and nothing else. */
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

typedef struct AowlOvVert {
    float    x, y;      /* pixels, top-left origin */
    float    u, v;
    uint32_t col;       /* R8G8B8A8_UNORM, so low byte is red */
} AowlOvVert;

/* 4096 quads. A full manager screen -- 22 rows, a four-line detail pane, a
 * wrapped reason and two legend lines -- is about 1,500 glyphs plus 60 solid
 * quads, so this is roughly a 2.5x margin and it is a flat 480 KB of .bss that
 * is never reallocated. Overflow is dropped by `aowl_ov_vert` rather than
 * grown: the render thread does not allocate. */
#define AOWL_OV_MAX_VERTS 24576

/* What the render thread asks the worker thread to do. Every one of these is a
 * request the manager already serves; none of them is a state change the
 * overlay makes on its own. */
typedef enum AowlOvCmdKind {
    AOWL_CMD_TOGGLE = 0,   /* POST /toggle/<id> {"enabled":..}  */
    AOWL_CMD_CLEAR,        /* GET  /clear/<id>                  */
    AOWL_CMD_SELECT,       /* GET  /select/<list-id>            */
    AOWL_CMD_APPLY,        /* GET  /apply                       */
    AOWL_CMD_RELOAD        /* GET  /reload                      */
} AowlOvCmdKind;

typedef struct AowlOvCmd {
    int32_t kind;
    char    guid[80];      /* the mod id, or the list id, or ""  */
    int32_t enabled;
} AowlOvCmd;

/* Which pane is on screen. */
typedef enum AowlOvView {
    AOWL_VIEW_MODS = 0,
    AOWL_VIEW_LISTS,
    AOWL_VIEW_ISSUES,
    AOWL_VIEW_APPLY,
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
    int32_t syncLen;
    int32_t syncSerial;                 /* bumped on every successful fetch */
    int32_t syncTaken;                  /* the serial the host last read */

    /* --- frame scratch and UI state, render thread only --- */
    AowlOvVert vtx[AOWL_OV_MAX_VERTS];
    int32_t    vtxCount;
    int32_t    frames;

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

    int32_t view;
    int32_t filter;
    int32_t scale;         /* 1, 2 or 3 -- see aowl_ov_scale */

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

    /* --- cost --- */
    LARGE_INTEGER qpcFreq;
    int32_t       drawn;        /* frames actually drawn; render thread only */
    int32_t       maxVtx;       /* the busiest frame's vertex count, ever */
    int32_t       vtxDropped;   /* quads the cap refused; must stay 0 */
    volatile LONG lastNs, avgNs, maxNs;
    volatile LONG avgBuildNs;   /* the geometry half, on its own */
} AowlOvState;

static AowlOvState g_ov;

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

/* ================================================================== *
 * The mod table
 * ================================================================== */

static void aowl_ov_copy(char* dst, int32_t cap, const char* src) {
    int32_t i = 0;
    if (!src) { dst[0] = 0; return; }
    for (; i < cap - 1 && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
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
     * thirty seconds — resolve/connect/send/receive, 500/800/800/1500 ms. */
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
         * The header asks the backend not to. It is ignored by the backend as it
         * stands today -- that is a change that has to be made there, and it is
         * written up in this directory's README -- so the check in the worker
         * names it in the status line rather than letting it look like a network
         * failure. */
        const wchar_t* hdr =
            body ? L"Content-Type: application/json\r\nAccept-Encoding: identity\r\n"
                 : L"Accept-Encoding: identity\r\n";
        DWORD hdrLen = (DWORD)wcslen(hdr);
        DWORD blen = body ? (DWORD)strlen(body) : 0;
        if (!g_wh.send(r, hdr, hdrLen, (LPVOID)body, blen, blen, 0)) goto done;
    }
    if (!g_wh.recv(r, NULL)) goto done;

    total = 0;
    for (;;) {
        DWORD avail = 0;
        if (!g_wh.avail(r, &avail) || avail == 0) break;
        if (total >= cap - 1) break;
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

static DWORD WINAPI aowl_ov_worker(LPVOID unused) {
    /* Static rather than automatic: 32 KB on a thread stack is affordable and
     * 32 KB that is allocated once is one fewer thing that can fail late.
     * `/aowlspt/mods/lists` on the shipped registry is about 2 KB; the ceiling
     * is what a very large registry could produce, and a body that does not fit
     * is truncated, fails to parse into rows, and leaves the tables alone. */
    static char buf[32768];
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
                _snprintf(jbody, sizeof(jbody), "{\"enabled\":%s}",
                          cmd.enabled ? "true" : "false");
                jbody[sizeof(jbody) - 1] = 0;
                postBody = jbody;
                verb = L"POST";
                _snprintf(what, sizeof(what), "%s %s",
                          cmd.enabled ? "enable" : "disable", cmd.guid);
            } else if (cmd.kind == AOWL_CMD_CLEAR) {
                _snwprintf(path, 224, L"/aowlspt/mods/clear/%ls", warg);
                _snprintf(what, sizeof(what), "clear override on %s", cmd.guid);
            } else if (cmd.kind == AOWL_CMD_SELECT) {
                _snwprintf(path, 224, L"/aowlspt/mods/select/%ls", warg);
                _snprintf(what, sizeof(what), "select list %s", cmd.guid);
            } else if (cmd.kind == AOWL_CMD_RELOAD) {
                _snwprintf(path, 224, L"/aowlspt/mods/reload");
                _snprintf(what, sizeof(what), "reload the registry");
            } else {
                _snwprintf(path, 224, L"/aowlspt/mods/apply");
                _snprintf(what, sizeof(what), "apply the selection");
            }
            path[223] = 0;
            what[sizeof(what) - 1] = 0;

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
                }
            }
        }

        Sleep(50);
        sinceFast += 50;
        sinceSlow += 50;
        sinceSync += 50;
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
#define AOWL_OV_LEGEND_H  40    /* two lines: the keys, and the markers */

static const uint32_t AOWL_OV_BG     = AOWL_RGBA(14, 16, 20, 232);
#define AOWL_OV_EDGE      AOWL_RGBA(120, 160, 200, 255)
#define AOWL_OV_TITLEBG   AOWL_RGBA(28, 34, 44, 255)
#define AOWL_OV_TEXT      AOWL_RGBA(226, 230, 236, 255)
#define AOWL_OV_DIM       AOWL_RGBA(130, 140, 152, 255)
#define AOWL_OV_FAINT     AOWL_RGBA(92, 100, 112, 255)
#define AOWL_OV_ON        AOWL_RGBA(70, 150, 90, 255)
#define AOWL_OV_OFF       AOWL_RGBA(120, 60, 60, 255)
#define AOWL_OV_HOT       AOWL_RGBA(80, 110, 150, 255)
#define AOWL_OV_SELBG     AOWL_RGBA(38, 58, 84, 255)
#define AOWL_OV_ROWALT    AOWL_RGBA(22, 26, 32, 200)
#define AOWL_OV_PANEBG    AOWL_RGBA(18, 21, 27, 255)
#define AOWL_OV_WARN      AOWL_RGBA(226, 170, 80, 255)
#define AOWL_OV_ERR       AOWL_RGBA(228, 110, 100, 255)
#define AOWL_OV_GOOD      AOWL_RGBA(120, 200, 140, 255)
#define AOWL_OV_ACCENT    AOWL_RGBA(150, 190, 235, 255)

static int32_t aowl_ov_hit(float x, float y, float w, float h) {
    /* The cursor is in back-buffer pixels and the rectangle is in panel units,
     * so the cursor comes down rather than the rectangle going up -- one divide
     * instead of four multiplies, and no rounding to disagree about. */
    float k = (float)(g_ov.scale > 0 ? g_ov.scale : 1);
    float mx = (float)g_ov.mx / k, my = (float)g_ov.my / k;
    return mx >= x && mx < x + w && my >= y && my < y + h;
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
 * them. Newlines in the source break the line too. */
static int32_t aowl_ov_wrap(float x, float y, const char* s, uint32_t col,
                            int32_t cols, int32_t maxLines) {
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
        aowl_ov_text(x, y + (float)(used * AOWL_OV_LINE_H), line, col);
        used++;
        i += take;
        while (s[i] == ' ') i++;
        if (s[i] == '\n') i++;
    }
    return used;
}

/* `_snprintf` does not always terminate on the Microsoft CRT. Every formatted
 * string in this file goes through here so that the exception does not have to
 * be remembered at thirty call sites. */
static void aowl_ov_fmt(char* out, int32_t cap, const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf(out, (size_t)cap - 1, fmt, ap);
    va_end(ap);
    out[cap - 1] = 0;
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
            _snprintf(g_ov.applyWhat, sizeof(g_ov.applyWhat),
                      "refused: disable %s (protected)", guid);
            g_ov.applyWhat[sizeof(g_ov.applyWhat) - 1] = 0;
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
    return g_ov.sResultCount;
}

static void aowl_ov_move(int32_t view, int32_t delta, int32_t count) {
    int32_t s = g_ov.sel[view] + delta;
    if (count <= 0) { g_ov.sel[view] = 0; return; }
    if (s < 0) s = 0;
    if (s >= count) s = count - 1;
    g_ov.sel[view] = s;
}

/* Drains the ring and turns it into actions. Runs on the render thread, once
 * per frame, so a key pressed between two frames is never lost and a key held
 * down repeats at the OS repeat rate rather than at the frame rate. `page` is
 * how far PgUp/PgDn moves, which depends on how tall the panel came out. */
static void aowl_ov_keys(int32_t page, const int32_t* vis, int32_t visN) {
    LONG vk;
    while (aowl_ov_pop_key(&vk)) {
        int32_t view = g_ov.view;
        int32_t count = aowl_ov_row_count(view, vis, visN);

        if (vk == VK_TAB || vk == VK_RIGHT) {
            g_ov.view = (view + 1) % AOWL_VIEW_COUNT;
            continue;
        }
        if (vk == VK_LEFT) {
            g_ov.view = (view + AOWL_VIEW_COUNT - 1) % AOWL_VIEW_COUNT;
            continue;
        }
        if (vk >= '1' && vk <= '4') { g_ov.view = (int32_t)(vk - '1'); continue; }
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

static void aowl_ov_tabs(float x, float y, float w, int32_t counts[4]) {
    static const char* names[AOWL_VIEW_COUNT] = { "MODS", "LISTS", "ISSUES", "APPLY" };
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

/* Refreshed on a timer rather than per frame -- see above. */
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
    aowl_ov_sig_add(&h, g_ov.dispRttMs);
    aowl_ov_sig_add(&h, g_ov.dispStaleS);
    /* Never zero: zero is what `aowl_ov_bind` writes to force the next frame to
     * rebuild after a device change. */
    return h ? h : 1u;
}

/* Builds the frame's geometry and consumes at most one click. Returns nothing;
 * everything it decides is either geometry or a queued command. */
static void aowl_ov_build(void) {
    float x = (float)AOWL_OV_PANEL_X, y = (float)AOWL_OV_PANEL_Y;
    float w, h, bodyY, bodyH, innerW;
    int32_t vis[AOWL_OV_MAX_MODS];
    int32_t visN, rows, counts[AOWL_VIEW_COUNT];
    char buf[256];
    uint32_t healthCol = AOWL_OV_DIM;

    aowl_ov_snapshot();
    aowl_ov_refresh_display();

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
    g_ov.scale = (g_ov.bbH >= 2500) ? 3 : (g_ov.bbH >= 1300) ? 2 : 1;
    {
        float availW = (g_ov.bbW ? (float)g_ov.bbW : 1280.0f) / (float)g_ov.scale;
        float availH = (g_ov.bbH ? (float)g_ov.bbH : 720.0f) / (float)g_ov.scale;
        /* The panel is sized to the room it has rather than to a constant. A
         * fixed 940x620 is fine at 1080p and taller than the window on the
         * 800x520 the test host resizes to mid-run, and a panel whose legend is
         * off the bottom of the screen is a panel with no legend. */
        w = (float)AOWL_OV_PANEL_W;
        if (w > availW - 2.0f * x) w = availW - 2.0f * x;
        if (w < 480.0f) w = 480.0f;
        h = (float)AOWL_OV_PANEL_H;
        if (h > availH - y - 30.0f) h = availH - y - 30.0f;
        if (h < 220.0f) h = 220.0f;
    }

    innerW = w - 2.0f * AOWL_OV_PAD;
    bodyY = y + (float)AOWL_OV_HEAD_H;
    bodyH = h - (float)AOWL_OV_HEAD_H - (float)AOWL_OV_LEGEND_H;

    visN = aowl_ov_visible_rows(vis);
    counts[AOWL_VIEW_MODS] = g_ov.sModCount;
    counts[AOWL_VIEW_LISTS] = g_ov.sListCount;
    counts[AOWL_VIEW_ISSUES] = g_ov.sIssueCount;
    counts[AOWL_VIEW_APPLY] = g_ov.sResultCount;

    /* Rows that fit. The mods view gives up the detail pane's height; the
     * others use the whole body. */
    rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H) / AOWL_OV_ROW_H);
    if (g_ov.view == AOWL_VIEW_MODS)
        rows = (int32_t)((bodyH - (float)AOWL_OV_LINE_H - (float)AOWL_OV_DETAIL_H)
                         / AOWL_OV_ROW_H);
    if (rows < 1) rows = 1;

    /* Input, before anything is drawn, so a keypress lands on this frame. The
     * wheel scrolls the current view by three rows a notch, which is what every
     * other list on Windows does. */
    aowl_ov_keys(rows, vis, visN);
    {
        LONG notches = InterlockedExchange(&g_ov.wheel, 0);
        if (notches)
            aowl_ov_move(g_ov.view, -3 * (int32_t)notches,
                         aowl_ov_row_count(g_ov.view, vis, visN));
        /* The filter may have changed under the cursor. */
        visN = aowl_ov_visible_rows(vis);
        counts[AOWL_VIEW_MODS] = g_ov.sModCount;
        if (g_ov.sel[AOWL_VIEW_MODS] >= visN)
            g_ov.sel[AOWL_VIEW_MODS] = visN > 0 ? visN - 1 : 0;
    }

    /* --- chrome --- */
    aowl_ov_rect(x, y, w, h, AOWL_OV_BG);
    aowl_ov_rect(x, y, w, (float)AOWL_OV_TITLE_H, AOWL_OV_TITLEBG);
    aowl_ov_frame_rect(x, y, w, h, 1.0f, AOWL_OV_EDGE);
    aowl_ov_text(x + AOWL_OV_PAD, y + 5.0f, "aowlspt  ::  mod manager", AOWL_OV_TEXT);
    {
        float tw;
        char cost[48];
        aowl_ov_health(buf, (int32_t)sizeof(buf), &healthCol);
        tw = (float)(strlen(buf) * AOWL_OV_CW);
        aowl_ov_text(x + w - AOWL_OV_PAD - tw, y + 5.0f, buf, healthCol);
        /* The frame cost, on the title bar, where it is visible from every view
         * -- an overlay in a game's present loop should be made to say what it
         * costs rather than be asked. Microseconds, one decimal, and the worst
         * frame since it opened beside it. */
        /* Dashes until there is a measurement. The first eight drawn frames
         * are dropped from the average deliberately (they are start-up, not the
         * overlay), and the display is refreshed twice a second, so there is a
         * moment after the panel opens with nothing to report -- and `0.0 us`
         * would be a claim rather than a gap. */
        if (g_ov.dispAvgNs > 0)
            aowl_ov_fmt(cost, sizeof(cost), "%d.%d us  peak %d.%d",
                        g_ov.dispAvgNs / 1000, (g_ov.dispAvgNs / 100) % 10,
                        g_ov.dispMaxNs / 1000, (g_ov.dispMaxNs / 100) % 10);
        else
            aowl_ov_fmt(cost, sizeof(cost), "-- us");
        aowl_ov_text(x + w - AOWL_OV_PAD - tw - 16.0f
                     - (float)(strlen(cost) * AOWL_OV_CW), y + 5.0f,
                     cost, AOWL_OV_FAINT);
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
    else
        aowl_ov_view_apply(x, bodyY, innerW, bodyH, rows);

    /* --- the legend ---
     *
     * Printed, always, on every view. A keyboard interface whose keys are not
     * on screen is a keyboard interface nobody can use, and this one is being
     * driven by somebody whose mouse is busy pointing a rifle. */
    {
        float ly = y + h - (float)AOWL_OV_LEGEND_H + 4.0f;
        int32_t cols = (int32_t)(innerW / AOWL_OV_CW);
        aowl_ov_rect(x + 1.0f, ly - 4.0f, w - 2.0f, 1.0f, AOWL_OV_EDGE);
        if (g_ov.view == AOWL_VIEW_MODS)
            aowl_ov_fmt(buf, sizeof(buf),
                        "TAB view  UP/DN move  SPACE toggle  C clear  "
                        "F filter [%s]  A apply  R reload  INS/ESC close",
                        aowl_ov_filter_name(g_ov.filter));
        else if (g_ov.view == AOWL_VIEW_LISTS)
            aowl_ov_fmt(buf, sizeof(buf),
                        "TAB view  UP/DN move  ENTER activate this list  "
                        "A apply  R reload  INS/ESC close");
        else
            aowl_ov_fmt(buf, sizeof(buf),
                        "TAB view  UP/DN move  1-4 jump  A apply  R reload  INS/ESC close");
        aowl_ov_textn(x + AOWL_OV_PAD, ly, buf, AOWL_OV_TEXT, cols);
        /* The second line is the marker legend, *unless* something went wrong
         * -- in which case it is what went wrong, on every view. An error you
         * have to change view to see is an error nobody sees, and the gestures
         * that fail (a refusal from the manager, a backend that is not there)
         * are made from the MODS view where the ISSUES tab is just a number.
         *
         * Which is also why no action here changes the view. Yanking the panel
         * to another pane because a keypress was refused loses the row the
         * player had selected, to tell them something a line of text can. */
        if (g_ov.sLastError[0])
            aowl_ov_textn(x + AOWL_OV_PAD, ly + (float)AOWL_OV_LINE_H,
                          g_ov.sLastError, AOWL_OV_ERR, cols);
        else {
            aowl_ov_fmt(buf, sizeof(buf),
                        /* 106 characters, and the room is 107 at the narrowest
                         * panel this draws at. A marker legend that runs off
                         * the right edge loses the marker nobody knows yet. */
                        "* your override   ~ asked, no answer yet   "
                        "! game disagrees   ON*/OFF* takes a restart   "
                        "dim = not running");
            aowl_ov_textn(x + AOWL_OV_PAD, ly + (float)AOWL_OV_LINE_H, buf,
                          AOWL_OV_FAINT, cols);
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

    ID3D11DeviceContext_Draw(c, (UINT)g_ov.vtxCount, 0);

    aowl_ov_restore(c, &saved);
}

/* ================================================================== *
 * Input
 * ================================================================== */

static LRESULT CALLBACK aowl_ov_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    WNDPROC old = g_ov.oldProc;

    if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
        if ((int32_t)wp == g_ov.toggleVk) {
            InterlockedExchange(&g_ov.visible, g_ov.visible ? 0 : 1);
            return 0;                       /* swallowed: never reaches the game */
        }
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
        case WM_RBUTTONDOWN:
        case WM_RBUTTONUP:
        case WM_MBUTTONDOWN:
        case WM_MBUTTONUP:
        case WM_KEYUP:
        case WM_SYSKEYUP:
        case WM_CHAR:
            return 0;
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
            if (wp == VK_ESCAPE) { InterlockedExchange(&g_ov.visible, 0); return 0; }
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
        if (aowl_ov_bind(sc) && g_ov.visible) {
            /* What one frame of this costs, measured rather than asserted. The
             * overlay is drawn inside the present loop of a game people play
             * competitively, so "it is cheap" is a claim that has to have a
             * number attached and the number has to come from the machine it is
             * running on. Two QPC reads is about forty nanoseconds and it buys
             * a figure the player can see in the legend. */
            LARGE_INTEGER t0, tb, t1;
            QueryPerformanceCounter(&t0);
            aowl_ov_build();
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
    g_ov.toggleVk = toggleVk ? toggleVk : VK_INSERT;
    g_ov.backendPort = backendPort;
    QueryPerformanceFrequency(&g_ov.qpcFreq);
    g_ov.view = AOWL_VIEW_MODS;
    g_ov.filter = AOWL_FILTER_ALL;
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
        _snprintf(msg, sizeof(msg), "could not hook Present (detour error %d)", rc);
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
        _snprintf(msg, sizeof(msg), "could not hook ResizeBuffers (detour error %d)", rc);
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
