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

#include "aowlspt_detour.h"

/* ================================================================== *
 * Public surface
 * ================================================================== */

#define AOWL_OV_MAX_MODS 64
#define AOWL_OV_MAX_CMDS 32

/* One row of the panel. Fixed-size fields rather than pointers: the render
 * thread reads this table every frame and a pointer into a string the worker
 * thread might be reallocating is a use-after-free waiting for a slow HTTP
 * response. */
typedef struct AowlOvMod {
    char    guid[80];
    char    name[64];
    char    version[24];
    int32_t enabled;    /* the desired state, as the manager resolves it      */
    int32_t loaded;     /* 1 when it is actually running                      */
    int32_t pending;    /* clicked, and the server has not confirmed yet      */
    int32_t restart;    /* the manager says this one only changes on restart  */
    int32_t hostPushed; /* the host told us about this row itself             */
} AowlOvMod;

/* `loaded` has two sources and they are not equal in authority.
 *
 * `hostPushed` marks the rows the host handed us through `aowl_ov_set_mod` --
 * mods loaded in *this* process, which is a fact the process cannot be wrong
 * about. The backend's `live` field is the *backend's* inventory, and the
 * manager runs on the server side: it has never heard of a client-only mod. So
 * a host-pushed row keeps its `loaded` no matter what the backend says, and a
 * backend that answers `"live":null` (it has no host control and does not know
 * what is running) leaves every row's `loaded` exactly where it was.
 *
 * Getting this backwards greys out every client-side mod the moment the panel
 * reaches a backend, which looks precisely like the overlay deciding nothing is
 * loaded. */

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

#define AOWL_OV_MAX_VERTS 6144   /* 1024 quads; the panel uses ~600 at 64 mods */

typedef struct AowlOvCmd {
    char    guid[80];
    int32_t enabled;
} AowlOvCmd;

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

    /* --- data --- */
    CRITICAL_SECTION cs;
    AowlOvMod        mods[AOWL_OV_MAX_MODS];
    int32_t          modCount;
    AowlOvCmd        cmds[AOWL_OV_MAX_CMDS];
    int32_t          cmdCount;
    int32_t          backendPort;
    volatile LONG    backendOk;

    HANDLE        worker;
    volatile LONG workerRun;
    AowlOvToggleFn toggleFn;
    void*          toggleUser;

    /* --- frame scratch, render thread only --- */
    AowlOvVert vtx[AOWL_OV_MAX_VERTS];
    int32_t    vtxCount;
    int32_t    frames;
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
    return m;
}

/* Called by the host once per mod it loaded. This is the read-only fallback:
 * if the backend is unreachable the panel still lists what is actually running
 * in this process, which is the information a player most wants and the one
 * source that cannot be wrong. */
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
        m->loaded = 1;
        m->hostPushed = 1;
    }
    LeaveCriticalSection(&g_ov.cs);
}

static void aowl_ov_clear_mods(void) {
    EnterCriticalSection(&g_ov.cs);
    g_ov.modCount = 0;
    LeaveCriticalSection(&g_ov.cs);
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
    g_wh.ok = (g_wh.open && g_wh.connect && g_wh.openReq && g_wh.send &&
               g_wh.recv && g_wh.avail && g_wh.read && g_wh.close) ? 1 : 0;
    return g_wh.ok;
}

/* Blocking. Worker thread only. Returns bytes written to `out`, or -1. */
static int32_t aowl_ov_http(const wchar_t* verb, const wchar_t* path,
                            const char* body, char* out, int32_t cap) {
    if (!aowl_ov_http_init()) return -1;
    AOWL_HINTERNET s = NULL, c = NULL, r = NULL;
    int32_t total = -1;

    s = g_wh.open(L"aowlspt-overlay/1.0", 0 /*WINHTTP_ACCESS_TYPE_DEFAULT_PROXY*/,
                  NULL, NULL, 0);
    if (!s) goto done;
    /* Short timeouts on every phase. This runs on our own thread, but a stalled
     * backend must not keep the overlay's "backend reachable" light green for
     * thirty seconds — resolve/connect/send/receive, 500/800/800/1500 ms. */
    if (g_wh.timeouts) g_wh.timeouts(s, 500, 800, 800, 1500);

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
    if (s) g_wh.close(s);
    return total;
}

/* ------------------------------------------------------------------ *
 * A deliberately small JSON reader.
 *
 * The schema is no longer a guess. `mods/manager` serves
 * `GET /aowlspt/mods/panel` specifically for this reader, and the shape is:
 *
 *   {"ok":true,"schema":"aowlspt.panel/1","side":"server","control":"absent",
 *    "liveKnown":false,"summary":"...","mods":[
 *      {"guid":"aowl.sain","id":"aowl.sain","name":"SAIN","version":"0.1.0",
 *       "enabled":true,"live":null,"restart":false,
 *       "verdict":"loaded","reason":"enabled by aowl.list.core"}, ...]}
 *
 * The manager's other routes -- `/aowlspt/mods/list` and friends -- carry the
 * same information in a shape built for a script: nested decision objects, no
 * version on the row, the version only reachable through a second request to
 * `/describe/<id>`. The rule this file is written under (see the header) is that
 * if the shapes do not fit, the *server* flattens them rather than this growing
 * a real parser, and that is what the panel route is. Nothing else consumes it,
 * so it can stay exactly the shape sixty lines of C can read.
 *
 * The alternative the earlier version of this comment proposed -- parse it in
 * nimony with `aowl/src/aowlspt/json.nim` and push rows in through
 * `aowl_ov_set_mod` -- was weighed and not taken. That parser would have to run
 * in the *client* host, which has no HTTP client of its own and no poll loop; it
 * would mean a second worker thread in nimony beside the one here, `aowlspt_net`
 * pulled into a DLL that is injected mid-startup, and all of it in a file this
 * directory does not own. Reconciling the schema on the server cost the manager
 * one route and this reader eight lines.
 *
 * Still tolerant of everything it can afford to be: a field it does not find is
 * left at whatever the host already told us, `"live":null` reads as "no change",
 * and an unrecognised body degrades to the host's own list rather than to an
 * empty panel. It is not a JSON parser and does not pretend to be: no escapes,
 * no nesting beyond skipping, no numbers.
 * ------------------------------------------------------------------ */

static const char* aowl_ov_jfind(const char* p, const char* end, const char* key) {
    size_t klen = strlen(key);
    for (const char* q = p; q + klen + 2 < end; q++) {
        if (q[0] == '"' && strncmp(q + 1, key, klen) == 0 && q[1 + klen] == '"') {
            const char* v = q + 2 + klen;
            while (v < end && (*v == ' ' || *v == ':')) v++;
            return v < end ? v : NULL;
        }
    }
    return NULL;
}

static void aowl_ov_jstr(const char* v, const char* end, char* out, int32_t cap) {
    out[0] = 0;
    if (!v || v >= end || *v != '"') return;
    v++;
    int32_t i = 0;
    while (v < end && *v != '"' && i < cap - 1) out[i++] = *v++;
    out[i] = 0;
}

static int32_t aowl_ov_jbool(const char* v, const char* end, int32_t dflt) {
    if (!v || v >= end) return dflt;
    if (*v == 't' || *v == '1') return 1;
    if (*v == 'f' || *v == '0') return 0;
    return dflt;
}

static void aowl_ov_ingest(const char* body, int32_t len) {
    const char* end = body + len;
    const char* p = body;
    int32_t seen = 0;

    /* Start at the array, not at the first brace. The wrapper object's own keys
     * sit before `"mods"`, and the scan below takes each `{`..`}` pair as a row
     * -- so from the top of the body the first "row" would be the wrapper's
     * scalars plus row zero's fields. It reads correctly by luck today because
     * the manager puts the scalars first and none of them is called `guid`.
     * Skipping to the key makes it correct by construction, and costs one
     * strstr-shaped loop. */
    {
        const char* a = aowl_ov_jfind(body, end, "mods");
        if (a && a < end) p = a;
    }

    EnterCriticalSection(&g_ov.cs);
    while (p < end && seen < AOWL_OV_MAX_MODS) {
        const char* o = (const char*)memchr(p, '{', (size_t)(end - p));
        if (!o) break;
        const char* c = (const char*)memchr(o, '}', (size_t)(end - o));
        if (!c) break;

        char guid[80];
        const char* g = aowl_ov_jfind(o, c, "guid");
        if (!g) g = aowl_ov_jfind(o, c, "id");
        aowl_ov_jstr(g, c, guid, (int32_t)sizeof(guid));
        if (guid[0]) {
            AowlOvMod* m = aowl_ov_row(guid);
            if (m) {
                char tmp[64];
                const char* n = aowl_ov_jfind(o, c, "name");
                if (n) {
                    aowl_ov_jstr(n, c, tmp, (int32_t)sizeof(tmp));
                    if (tmp[0]) aowl_ov_copy(m->name, (int32_t)sizeof(m->name), tmp);
                }
                const char* ver = aowl_ov_jfind(o, c, "version");
                if (ver) {
                    aowl_ov_jstr(ver, c, tmp, (int32_t)sizeof(tmp));
                    if (tmp[0])
                        aowl_ov_copy(m->version, (int32_t)sizeof(m->version), tmp);
                }
                const char* e = aowl_ov_jfind(o, c, "enabled");
                int32_t want = aowl_ov_jbool(e, c, m->enabled);
                /* Only the backend's answer clears `pending`. The row shows a
                 * `~` from the moment it is clicked until the server confirms
                 * the state we asked for, so a POST that silently failed stays
                 * visible on the panel rather than looking applied. */
                if (m->pending && want == m->enabled) m->pending = 0;
                m->enabled = want;

                /* `live` is what the *manager* knows is running, and it is only
                 * a fact when a host has answered its control probe -- until
                 * then the manager sends null and `aowl_ov_jbool` hands back the
                 * default, which is this row's existing value. A row the host
                 * pushed in is never lowered by it: see the note on
                 * `hostPushed`. */
                const char* lv = aowl_ov_jfind(o, c, "live");
                if (lv && !m->hostPushed)
                    m->loaded = aowl_ov_jbool(lv, c, m->loaded);

                /* The `*` on the row. This is the whole point of the schema
                 * reconciliation: it used to be a constant -- every toggle was
                 * "applies on restart" because nothing could ask. Now it is the
                 * manager's per-mod answer, and a mod the host really did unload
                 * live comes back with restart:false and loaded:0. */
                const char* rs = aowl_ov_jfind(o, c, "restart");
                if (rs) m->restart = aowl_ov_jbool(rs, c, m->restart);
                seen++;
            }
        }
        p = c + 1;
    }
    LeaveCriticalSection(&g_ov.cs);
}

static DWORD WINAPI aowl_ov_worker(LPVOID unused) {
    (void)unused;
    static char buf[16384];
    /* Starts at the interval so the first poll happens immediately: an
     * overlay that shows a stale read-only list for a second after the
     * game starts looks broken. */
    int32_t sinceRefresh = 1000;

    while (g_ov.workerRun) {
        /* Commands first: a click should not wait out the poll interval. */
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

        if (have) {
            wchar_t path[192];
            wchar_t wguid[80];
            int32_t i = 0;
            for (; cmd.guid[i] && i < 79; i++) wguid[i] = (wchar_t)(unsigned char)cmd.guid[i];
            wguid[i] = 0;
            /* `mods/manager` serves this: it sets the override, re-resolves,
             * and then asks the host to make it true, all in the one request.
             * The panel has one button per row and no separate `apply`, so a
             * toggle that only recorded an intention would need a second gesture
             * this UI does not have. */
            _snwprintf(path, 192, L"/aowlspt/mods/toggle/%ls", wguid);
            path[191] = 0;
            char body[48];
            _snprintf(body, sizeof(body), "{\"enabled\":%s}",
                      cmd.enabled ? "true" : "false");
            int32_t rc = aowl_ov_http(L"POST", path, body, buf, (int32_t)sizeof(buf));
            InterlockedExchange(&g_ov.backendOk, rc >= 0 ? 1 : 0);
            if (g_ov.toggleFn) g_ov.toggleFn(cmd.guid, cmd.enabled, g_ov.toggleUser);
            sinceRefresh = 1000;   /* force a re-read so the panel shows truth */
        }

        if (sinceRefresh >= 1000) {
            sinceRefresh = 0;
            int32_t rc = aowl_ov_http(L"GET", L"/aowlspt/mods/panel", NULL, buf,
                                      (int32_t)sizeof(buf));
            if (rc > 1 && (unsigned char)buf[0] == 0x78) {
                /* A zlib stream, not JSON. Named exactly, because every other
                 * symptom of it -- an empty panel, a "backend up" light over a
                 * read-only list -- points at the wrong half of the system. */
                InterlockedExchange(&g_ov.backendOk, 0);
                aowl_ov_note("backend answered with a deflated body; it must "
                             "honour Accept-Encoding: identity (see "
                             "host/Aowlspt.Overlay/README.md)");
            } else if (rc > 0) {
                InterlockedExchange(&g_ov.backendOk, 1);
                aowl_ov_ingest(buf, rc);
            } else {
                InterlockedExchange(&g_ov.backendOk, 0);
            }
        }
        Sleep(50);
        sinceRefresh += 50;
    }
    return 0;
}

static void aowl_ov_queue(const char* guid, int32_t enabled) {
    EnterCriticalSection(&g_ov.cs);
    if (g_ov.cmdCount < AOWL_OV_MAX_CMDS) {
        aowl_ov_copy(g_ov.cmds[g_ov.cmdCount].guid, 80, guid);
        g_ov.cmds[g_ov.cmdCount].enabled = enabled;
        g_ov.cmdCount++;
    }
    LeaveCriticalSection(&g_ov.cs);
}

/* ================================================================== *
 * Immediate-mode drawing
 *
 * One vertex buffer, one draw call, no index buffer. Six vertices per quad
 * rather than four plus indices: at a thousand quads the extra 40 KB of upload
 * is free and it removes an IA state (and its backup/restore) from the frame.
 * ================================================================== */

static void aowl_ov_vert(float x, float y, float u, float v, uint32_t col) {
    if (g_ov.vtxCount >= AOWL_OV_MAX_VERTS) return;
    AowlOvVert* p = &g_ov.vtx[g_ov.vtxCount++];
    p->x = x; p->y = y; p->u = u; p->v = v; p->col = col;
}

static void aowl_ov_quad_uv(float x, float y, float w, float h,
                            float u0, float v0, float u1, float v1, uint32_t col) {
    if (g_ov.vtxCount + 6 > AOWL_OV_MAX_VERTS) return;
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
 * ================================================================== */

#define AOWL_OV_PANEL_W  520
#define AOWL_OV_ROW_H    22
#define AOWL_OV_PAD      10
#define AOWL_OV_BTN_W    56

static const uint32_t AOWL_OV_BG     = AOWL_RGBA(14, 16, 20, 232);
#define AOWL_OV_EDGE      AOWL_RGBA(120, 160, 200, 255)
#define AOWL_OV_TITLEBG   AOWL_RGBA(28, 34, 44, 255)
#define AOWL_OV_TEXT      AOWL_RGBA(226, 230, 236, 255)
#define AOWL_OV_DIM       AOWL_RGBA(130, 140, 152, 255)
#define AOWL_OV_ON        AOWL_RGBA(70, 150, 90, 255)
#define AOWL_OV_OFF       AOWL_RGBA(120, 60, 60, 255)
#define AOWL_OV_HOT       AOWL_RGBA(80, 110, 150, 255)
#define AOWL_OV_ROWALT    AOWL_RGBA(22, 26, 32, 200)

static int32_t aowl_ov_hit(float x, float y, float w, float h) {
    float mx = (float)g_ov.mx, my = (float)g_ov.my;
    return mx >= x && mx < x + w && my >= y && my < y + h;
}

/* Builds the frame's geometry and consumes at most one click. Returns nothing;
 * everything it decides is either geometry or a queued command. */
static void aowl_ov_build(void) {
    g_ov.vtxCount = 0;

    /* A snapshot under the lock, so the rest of the frame does not hold it.
     * The worker thread can be mid-HTTP-response while this runs. */
    AowlOvMod rows[AOWL_OV_MAX_MODS];
    int32_t n;
    EnterCriticalSection(&g_ov.cs);
    n = g_ov.modCount;
    memcpy(rows, g_ov.mods, sizeof(AowlOvMod) * (size_t)n);
    LeaveCriticalSection(&g_ov.cs);

    int32_t click = InterlockedExchange(&g_ov.clickDown, 0);

    float x = 40.0f, y = 60.0f;
    float w = (float)AOWL_OV_PANEL_W;
    float h = (float)(34 + AOWL_OV_ROW_H * (n > 0 ? n : 1) + 30);

    aowl_ov_rect(x, y, w, h, AOWL_OV_BG);
    aowl_ov_rect(x, y, w, 26.0f, AOWL_OV_TITLEBG);
    aowl_ov_frame_rect(x, y, w, h, 1.0f, AOWL_OV_EDGE);
    aowl_ov_text(x + AOWL_OV_PAD, y + 5.0f, "aowlspt  ::  mods", AOWL_OV_TEXT);

    {
        char hdr[64];
        _snprintf(hdr, sizeof(hdr), "%s  f%d",
                  g_ov.backendOk ? "backend up" : "read-only", g_ov.frames);
        hdr[63] = 0;
        float tw = (float)(strlen(hdr) * AOWL_OV_CW);
        aowl_ov_text(x + w - AOWL_OV_PAD - tw, y + 5.0f, hdr,
                     g_ov.backendOk ? AOWL_OV_TEXT : AOWL_OV_DIM);
    }

    float ry = y + 30.0f;
    if (n == 0) {
        aowl_ov_text(x + AOWL_OV_PAD, ry + 3.0f, "no mods reported", AOWL_OV_DIM);
        ry += AOWL_OV_ROW_H;
    }
    for (int32_t i = 0; i < n; i++) {
        AowlOvMod* m = &rows[i];
        if (i & 1) aowl_ov_rect(x + 1.0f, ry, w - 2.0f, (float)AOWL_OV_ROW_H,
                                AOWL_OV_ROWALT);

        char line[64];
        _snprintf(line, sizeof(line), "%-30.30s %-10.10s",
                  m->name[0] ? m->name : m->guid, m->version);
        line[63] = 0;
        aowl_ov_text(x + AOWL_OV_PAD, ry + 3.0f, line,
                     m->loaded ? AOWL_OV_TEXT : AOWL_OV_DIM);

        float bx = x + w - AOWL_OV_PAD - (float)AOWL_OV_BTN_W;
        float by = ry + 2.0f;
        float bh = (float)(AOWL_OV_ROW_H - 4);
        int32_t hot = aowl_ov_hit(bx, by, (float)AOWL_OV_BTN_W, bh);
        aowl_ov_rect(bx, by, (float)AOWL_OV_BTN_W, bh,
                     hot ? AOWL_OV_HOT : (m->enabled ? AOWL_OV_ON : AOWL_OV_OFF));
        aowl_ov_frame_rect(bx, by, (float)AOWL_OV_BTN_W, bh, 1.0f, AOWL_OV_EDGE);
        /* Three states in four characters, and each one means one thing.
         *   ` ON ` / ` OFF`  what the manager resolves this mod to
         *   `~`              clicked; the server has not answered yet
         *   `*`              the manager says it only changes on a restart
         * `~` wins the slot while both are true: an outstanding request is the
         * more recent fact, and the `*` comes back one poll later if the answer
         * was a deferral. */
        const char* label = m->pending ? (m->enabled ? " ON ~" : " OFF~")
                          : m->restart ? (m->enabled ? " ON *" : " OFF*")
                                       : (m->enabled ? " ON " : " OFF");
        aowl_ov_text(bx + 6.0f, by + 1.0f, label, AOWL_OV_TEXT);

        if (click && hot) {
            /* Flip the row locally so the button answers immediately, and mark
             * it pending: a native mod cannot be unloaded from under a running
             * raid, so the honest meaning of this button is "next launch". */
            EnterCriticalSection(&g_ov.cs);
            for (int32_t k = 0; k < g_ov.modCount; k++) {
                if (strcmp(g_ov.mods[k].guid, m->guid) == 0) {
                    g_ov.mods[k].enabled = !g_ov.mods[k].enabled;
                    g_ov.mods[k].pending = 1;
                    LeaveCriticalSection(&g_ov.cs);
                    aowl_ov_queue(m->guid, g_ov.mods[k].enabled);
                    goto clicked;
                }
            }
            LeaveCriticalSection(&g_ov.cs);
        clicked:
            click = 0;
        }
        ry += AOWL_OV_ROW_H;
    }

    /* Both markers explained, because a `*` with no legend is a rumour. And it
     * is deliberately no longer the unconditional "applies on restart": that was
     * true while the panel had nothing to ask, and it is exactly the claim this
     * change exists to stop making. */
    aowl_ov_text(x + AOWL_OV_PAD, ry + 6.0f,
                 "~ waiting on the server   * needs a restart   dim = not loaded",
                 AOWL_OV_DIM);

    /* Our own cursor. The game hides the OS cursor in a raid and keeps its own
     * ShowCursor count; calling ShowCursor here would fight that counter and
     * leave the cursor stuck when the overlay closes. Drawing a marker costs
     * two quads and touches nothing. */
    {
        float mx = (float)g_ov.mx, my = (float)g_ov.my;
        aowl_ov_rect(mx, my, 2.0f, 12.0f, AOWL_OV_TEXT);
        aowl_ov_rect(mx, my, 12.0f, 2.0f, AOWL_OV_TEXT);
    }
}

static void aowl_ov_draw(IDXGISwapChain* sc) {
    ID3D11DeviceContext* c = g_ov.ctx;

    if (g_ov.vtxCount <= 0) return;

    AowlOvSaved saved;
    aowl_ov_save(c, &saved);

    D3D11_MAPPED_SUBRESOURCE map;
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
        case WM_LBUTTONUP:
        case WM_RBUTTONDOWN:
        case WM_RBUTTONUP:
        case WM_MBUTTONDOWN:
        case WM_MBUTTONUP:
        case WM_MOUSEWHEEL:
        case WM_KEYUP:
        case WM_SYSKEYUP:
        case WM_CHAR:
            return 0;
        case WM_KEYDOWN:
            /* Escape closes, everything else is eaten so WASD does not walk
             * the player into a wall while the panel is open. */
            if (wp == VK_ESCAPE) InterlockedExchange(&g_ov.visible, 0);
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
            aowl_ov_build();
            aowl_ov_draw(sc);
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
 * why, in a form meant to be logged verbatim. */
static int32_t aowl_ov_start(int32_t toggleVk, int32_t backendPort) {
    if (InterlockedCompareExchange(&g_ov.started, 1, 0) != 0) return 1;

    /* `aowl_ov_stop` latches `broken` on the way out so the detours become
     * pass-throughs while they are still installed; a later start has to clear
     * it or it would come up already dead. */
    InterlockedExchange(&g_ov.broken, 0);
    InitializeCriticalSection(&g_ov.cs);
    g_ov.toggleVk = toggleVk ? toggleVk : VK_INSERT;
    g_ov.backendPort = backendPort;
    aowl_ov_note("starting");

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

    if (backendPort > 0) {
        g_ov.workerRun = 1;
        g_ov.worker = CreateThread(NULL, 0, aowl_ov_worker, NULL, 0, NULL);
    }

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
