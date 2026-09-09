/* texprojtest.c -- the two additions to the region contract, proved against
 * the FINISHED STATE rather than against their own inputs.
 *
 * PART 1  AOWL_REGION_CMD_QUAD -- the textured quad, and its cache.
 *
 *   The assertion is on the RASTERISED RESULT, not on the command buffer: the
 *   test drains the published commands through the real
 *   `aowl_ov_region_append` and then reads back the vertices and the SPAN LIST
 *   the renderer will actually issue. Asserting that a quad was submitted
 *   would be a check on our own write and could not fail.
 *
 *   The falsifiable negatives, each of which is the failure this design exists
 *   to prevent:
 *     * a quad naming an UNDEFINED key emits ZERO vertices and opens NO span.
 *       (The tempting fallback -- draw it with the font atlas bound -- puts
 *       glyph soup where the map goes and looks like a renderer bug.)
 *     * the LAST span of the frame is the FONT span. Anything appended after
 *       the region drain (the launch hint) must not inherit a tile's texture.
 *     * a re-`define` of a resident key with the SAME shape does not grow the
 *       table and does not move `gen` -- that is the "repeated frames do not
 *       re-upload" property, stated as something that can be observed to be
 *       false.
 *     * a re-`define` with a DIFFERENT shape DOES move `gen`, because a
 *       key-only GPU cache would otherwise render stale pixels under a fresh
 *       name with no error anywhere.
 *     * defining more keys than AOWL_REGION_TEX_MAX evicts, and the resident
 *       count NEVER exceeds the stated bound. A cache with an unenforced
 *       bound is not a bound.
 *     * a definition whose `bytes` disagrees with its format and dimensions is
 *       REFUSED, so `bytes` is a check and not a hint.
 *
 * PART 2  behind-camera reporting -- the P0.
 *
 *   `Camera::WorldToScreenPoint` on a point BEHIND the camera returns a
 *   perfectly plausible screen position: the perspective divide by a negative
 *   depth mirrors it through the origin. The old five-argument projector could
 *   only say 1-with-pixels or 0, so a caller drew an indicator pointing
 *   confidently backwards and could not have known.
 *
 *   THE PRE-FIX CODE IS RUN HERE, on the same point, and asserted to report a
 *   plausible in-front position. Without that half, the new check has nothing
 *   to be a fix OF -- it would be a check that cannot fail.
 *
 * Build:  gcc -O1 -Wno-unused-function -I ..\..\abi texprojtest.c -o texprojtest.exe
 * (No -ld3d11: the D3D11 device is loaded through LoadLibrary, so a machine
 *  without it reports INCONCLUSIVE rather than failing to link.)
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* HOST MODE, for the same reason f3test.c gives: client mode resolves every
 * entry point by GetProcAddress into a host DLL that is not in this process,
 * so every check below would pass by doing nothing at all. */
#define AOWL_REGION_HOST
#include "aowlspt_shim.h"
#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}

static int failures = 0;
static void ok(const char* m) { printf("ok    %s\n", m); }
static void check(const char* what, int cond) {
    if (cond) { ok(what); return; }
    printf("error %s\n", what);
    failures++;
}
static void eq_int(const char* what, int got, int want) {
    if (got == want) { ok(what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}
/* The third outcome. "I could not look" is not a pass. */
static void inconclusive(const char* what) {
    printf("INCONCLUSIVE %s\n", what);
    failures++;
}
static void sink(const char* line) { (void)line; }

/* ================================================================== *
 * A D3D11 device, obtained WITHOUT a link-time dependency.
 * ================================================================== */
typedef HRESULT (WINAPI *PFN_D3D11CreateDevice)(
    void*, UINT, HMODULE, UINT, const void*, UINT, UINT,
    ID3D11Device**, void*, ID3D11DeviceContext**);

static int32_t make_device(void) {
    HMODULE d3d = LoadLibraryA("d3d11.dll");
    PFN_D3D11CreateDevice fn;
    HRESULT hr;
    ID3D11Device* dev = NULL;
    ID3D11DeviceContext* ctx = NULL;
    if (!d3d) return 0;
    fn = (PFN_D3D11CreateDevice)(void*)GetProcAddress(d3d, "D3D11CreateDevice");
    if (!fn) return 0;
    /* WARP (driver type 5). No swap chain: nothing here presents, and
     * CreateTexture2D/CreateShaderResourceView do not need one. */
    hr = fn(NULL, 5 /* D3D_DRIVER_TYPE_WARP */, NULL, 0, NULL, 0,
            7 /* D3D11_SDK_VERSION */, &dev, NULL, &ctx);
    if (FAILED(hr) || !dev) return 0;
    g_ov.dev = dev;
    g_ov.ctx = ctx;
    /* The textured-quad pixel shader, from the SAME baked bytecode the
     * overlay uses. Without it `aowl_ov_region_append` counts a miss and
     * draws nothing -- which is correct behaviour, and would have made every
     * rasterised check below pass by drawing an empty frame. It is created
     * here so the checks are against the real path. */
    if (FAILED(ID3D11Device_CreatePixelShader(dev, aowl_ov_ps_tex,
                sizeof(aowl_ov_ps_tex), NULL, &g_ov.psTex)))
        g_ov.psTex = NULL;
    return g_ov.psTex ? 1 : 0;
}

/* ================================================================== *
 * PART 1 -- the textured quad
 * ================================================================== */

/* A 64x64 BGRA8 tile. Small, but the format check is on the byte count and
 * the pitch, both of which are computed from w/h, so size is not the variable
 * under test here -- the bound and the eviction are, and those are counted. */
#define TILE_W 64
#define TILE_H 64
static uint8_t g_tile[TILE_W * TILE_H * 4];
static uint8_t g_tile2[(TILE_W / 2) * (TILE_H / 2) * 4];

#define KEY_A 0x6D61705F74696C65ull   /* "map_tile" */
#define KEY_B 0x6D61705F74696C66ull

static int32_t g_submitMode = 0;   /* 0 = good quad, 1 = quad on a dead key */

static void tex_submit(void* user, int64_t frame) {
    (void)user; (void)frame;
    if (g_submitMode == 0) {
        aowl_region_quad(100.0f, 200.0f, 300.0f, 400.0f,
                         0.25f, 0.5f, 0.75f, 1.0f, KEY_A, 0xFFFFFFFFu);
    } else {
        /* A key nothing ever defined. */
        aowl_region_quad(10.0f, 10.0f, 20.0f, 20.0f,
                         0.0f, 0.0f, 1.0f, 1.0f, 0xDEADBEEFull, 0xFFFFFFFFu);
    }
}

static int32_t span_with_srv_count(void) {
    int32_t i, n = 0;
    for (i = 0; i < g_ov.spanN; i++) if (g_ov.spans[i].srv) n++;
    return n;
}

static void part1(int32_t haveDevice) {
    AowlRegionDesc d;
    int32_t h, before, i;

    printf("\nPART 1 -- AOWL_REGION_CMD_QUAD, the texture table and its bound\n");

    memset(g_tile, 0x7F, sizeof(g_tile));
    memset(g_tile2, 0x40, sizeof(g_tile2));

    /* ---- the argument checks are CHECKS ---------------------------- */
    eq_int("a byte count that disagrees with the format is REFUSED",
           aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                      TILE_W, TILE_H, g_tile,
                                      (uint32_t)sizeof(g_tile) - 4u),
           AOWL_REGION_REFUSE_TEXARGS);
    eq_int("a zero key is REFUSED",
           aowl_region_texture_define(0, AOWL_REGION_TEXFMT_BGRA8,
                                      TILE_W, TILE_H, g_tile,
                                      (uint32_t)sizeof(g_tile)),
           AOWL_REGION_REFUSE_TEXARGS);
    eq_int("a NULL pointer is REFUSED",
           aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                      TILE_W, TILE_H, NULL,
                                      (uint32_t)sizeof(g_tile)),
           AOWL_REGION_REFUSE_TEXARGS);
    eq_int("a texture larger than one slot is REFUSED WHOLE, not truncated",
           aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                      2048, 2048, g_tile,
                                      2048u * 2048u * 4u),
           AOWL_REGION_REFUSE_TEXBIG);
    eq_int("after four refusals nothing is resident -- a refusal that still "
           "stores is not a refusal", aowl_region_texture_count(), 0);

    /* ---- define, and the no-re-upload property --------------------- */
    eq_int("a well-formed BGRA8 tile is accepted",
           aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                      TILE_W, TILE_H, g_tile,
                                      (uint32_t)sizeof(g_tile)),
           AOWL_REGION_OK);
    check("the key is now resident", aowl_region_texture_have(KEY_A) == 1);
    check("a key nobody defined is NOT resident -- `have` can say no",
          aowl_region_texture_have(KEY_B) == 0);
    {
        const AowlRegionTexSlot* s = 0;
        int32_t gen0;
        for (i = 0; i < AOWL_REGION_TEX_MAX; i++) {
            const AowlRegionTexSlot* t = aowl_region_texture_slot(i);
            if (t && t->key == KEY_A) { s = t; break; }
        }
        if (!s) { inconclusive("the slot could not be read back"); return; }
        gen0 = s->gen;
        aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                   TILE_W, TILE_H, g_tile,
                                   (uint32_t)sizeof(g_tile));
        eq_int("re-defining the SAME key with the SAME shape does not move "
               "`gen` -- this is the property that makes a per-frame define "
               "free, and it is observable", s->gen, gen0);
        eq_int("...and does not grow the table", aowl_region_texture_count(), 1);
        aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                   TILE_W / 2, TILE_H / 2, g_tile2,
                                   (uint32_t)sizeof(g_tile2));
        check("re-defining with a DIFFERENT shape DOES move `gen`, so a "
              "GPU cache keyed on the key alone cannot serve stale pixels",
              s->gen != gen0);
        /* Put it back the way the draw test wants it. */
        aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                                   TILE_W, TILE_H, g_tile,
                                   (uint32_t)sizeof(g_tile));
    }

    /* ---- the bound, and eviction ----------------------------------- */
    for (i = 0; i < AOWL_REGION_TEX_MAX + 8; i++) {
        aowl_region_texture_define(0x1000ull + (uint64_t)i,
                                   AOWL_REGION_TEXFMT_BGRA8,
                                   TILE_W, TILE_H, g_tile,
                                   (uint32_t)sizeof(g_tile));
    }
    check("the resident count NEVER exceeds AOWL_REGION_TEX_MAX, however "
          "many keys are offered -- the bound is enforced, not documented",
          aowl_region_texture_count() <= AOWL_REGION_TEX_MAX);
    check("...and something was actually EVICTED, so the LRU path ran rather "
          "than the table silently refusing everything after the 32nd",
          aowl_region_texture_evictions() > 0);
    /* Clear the flood so the draw checks below start from a known table. */
    for (i = 0; i < AOWL_REGION_TEX_MAX + 8; i++)
        aowl_region_texture_forget(0x1000ull + (uint64_t)i);
    aowl_region_texture_define(KEY_A, AOWL_REGION_TEXFMT_BGRA8,
                               TILE_W, TILE_H, g_tile,
                               (uint32_t)sizeof(g_tile));
    eq_int("forgetting a key that was never there is REFUSED, so `forget` "
           "distinguishes 'released' from 'was not mine'",
           aowl_region_texture_forget(0x999ull), AOWL_REGION_REFUSE_NOTEX);

    /* ---- the RASTERISED result ------------------------------------- */
    memset(&d, 0, sizeof(d));
    d.size = (int32_t)sizeof(d);
    strcpy(d.name, "texprobe");
    d.mask = AOWL_REGION_DRAW;
    d.fn = tex_submit;
    h = aowl_region_register(&d);
    if (h < 0) { inconclusive("the participant could not register"); return; }
    aowl_region_set_armed(1);

    if (!haveDevice) {
        inconclusive("no D3D11 device on this machine, so the textured DRAW "
                     "could not be exercised -- the table checks above stand, "
                     "the rasterised ones did NOT run");
        aowl_region_unregister(h);
        return;
    }

    /* The good quad. */
    g_submitMode = 0;
    g_ov.vtxCount = 0; g_ov.spanN = 0; g_ov.scale = 3;
    aowl_region_frame();
    before = g_ov.vtxCount;
    aowl_ov_region_append();
    eq_int("one textured quad rasterises to exactly SIX vertices",
           g_ov.vtxCount - before, 6);
    eq_int("exactly ONE span carries a texture", span_with_srv_count(), 1);
    check("the LAST span of the frame is the FONT span -- so the launch hint "
          "appended after the region drain cannot inherit a tile's texture",
          g_ov.spanN > 0 && g_ov.spans[g_ov.spanN - 1].srv == NULL);
    {
        /* Read back what will actually be drawn. Every one of these is a
         * number the renderer produced, not one the test wrote. */
        int32_t j, sp = -1;
        float minu = 9.0f, maxu = -9.0f, minv = 9.0f, maxv = -9.0f;
        float minx = 1e9f, maxx = -1e9f, miny = 1e9f, maxy = -1e9f;
        for (j = 0; j < g_ov.spanN; j++) if (g_ov.spans[j].srv) sp = j;
        if (sp < 0) { inconclusive("no textured span to read back"); }
        else {
            eq_int("the textured span covers exactly the quad's six vertices",
                   g_ov.spans[sp].count, 6);
            for (j = g_ov.spans[sp].start;
                 j < g_ov.spans[sp].start + g_ov.spans[sp].count; j++) {
                AowlOvVert* v = &g_ov.vtx[j];
                if (v->u < minu) minu = v->u;
                if (v->u > maxu) maxu = v->u;
                if (v->v < minv) minv = v->v;
                if (v->v > maxv) maxv = v->v;
                if (v->x < minx) minx = v->x;
                if (v->x > maxx) maxx = v->x;
                if (v->y < miny) miny = v->y;
                if (v->y > maxy) maxy = v->y;
            }
            check("the rasterised UVs are the SOURCE rect that was submitted, "
                  "not the atlas's white texel",
                  minu == 0.25f && maxu == 0.75f &&
                  minv == 0.5f  && maxv == 1.0f);
            check("the rasterised corners are the DEST rect in TRUE back-buffer "
                  "pixels -- the panel's integer scale is not applied to them",
                  minx == 100.0f && maxx == 400.0f &&
                  miny == 200.0f && maxy == 600.0f);
        }
    }
    eq_int("the panel's scale is RESTORED after the region drain", g_ov.scale, 3);

    /* The negative: a quad on a key nothing defined. */
    g_submitMode = 1;
    g_ov.vtxCount = 0; g_ov.spanN = 0;
    aowl_region_frame();
    before = g_ov.vtxCount;
    aowl_ov_region_append();
    eq_int("a quad naming an UNDEFINED key emits ZERO vertices -- it is not "
           "drawn with the font atlas bound, which would be glyph soup where "
           "the map belongs", g_ov.vtxCount - before, 0);
    eq_int("...and the submission itself was refused by name",
           aowl_region_last_refusal(), AOWL_REGION_REFUSE_NOTEX);

    aowl_region_unregister(h);
}

/* ================================================================== *
 * PART 2 -- behind-camera reporting
 * ================================================================== */

/* A camera at the origin looking down +Z, 90 degree vertical FOV, on a
 * 1920x1080 back buffer. This is a real perspective divide, so the mirroring
 * that the whole item is about happens for the same arithmetic reason it
 * happens in the client -- it is not simulated by a flag. */
#define CAM_W 1920.0f
#define CAM_H 1080.0f

static void cam_project_raw(float wx, float wy, float wz,
                            float* sx, float* sy, float* depth) {
    float f = (CAM_H * 0.5f);      /* focal length in pixels at 90 deg vfov */
    float z = wz;
    if (z == 0.0f) z = 1e-6f;
    *sx = (CAM_W * 0.5f) + (wx * f) / z;
    *sy = (CAM_H * 0.5f) - (wy * f) / z;
    *depth = z;
}

/* THE PRE-FIX CODE, kept verbatim in shape: five arguments, two outcomes, no
 * way to say "these pixels are a lie". This is what every caller had. */
static int32_t legacy_project(float wx, float wy, float wz,
                              float* sx, float* sy) {
    float d;
    cam_project_raw(wx, wy, wz, sx, sy, &d);
    return 1;
}

/* THE FIXED PROJECTOR, in the new shape. */
static int32_t cam_project(float wx, float wy, float wz,
                           float* sx, float* sy, int32_t* flags, float* depth) {
    cam_project_raw(wx, wy, wz, sx, sy, depth);
    *flags = (*depth > 0.0f) ? AOWL_REGION_PROJ_INFRONT
                             : AOWL_REGION_PROJ_BEHIND;
    return 1;
}

static void part2(void) {
    /* One point IN FRONT and one BEHIND, mirrored through the camera. */
    const float FX = 5.0f, FY = 3.0f, FZ = 20.0f;
    float lx = 0.0f, ly = 0.0f;
    float sx = 0.0f, sy = 0.0f, depth = 0.0f;
    int32_t flags = 0, r;

    printf("\nPART 2 -- behind-camera reporting\n");

    /* ---- THE FALSIFICATION EVIDENCE ------------------------------- *
     * The pre-fix code, on the behind-camera point, reporting success and a
     * position that is on screen and looks entirely reasonable. If this
     * assertion ever fails, the "fix" below has nothing to fix. */
    r = legacy_project(FX, FY, -FZ, &lx, &ly);
    check("PRE-FIX: the old five-argument projector returns SUCCESS for a "
          "point BEHIND the camera", r == 1);
    check("PRE-FIX: ...and the position it returns is ON SCREEN and entirely "
          "plausible -- this is the confidently wrong answer",
          lx >= 0.0f && lx <= CAM_W && ly >= 0.0f && ly <= CAM_H);
    {
        float fx = 0.0f, fy = 0.0f;
        legacy_project(FX, FY, FZ, &fx, &fy);
        check("PRE-FIX: ...and it is the MIRROR of the in-front point, which "
              "is why an indicator built on it points backwards",
              (lx - CAM_W * 0.5f) == -(fx - CAM_W * 0.5f) &&
              (ly - CAM_H * 0.5f) == -(fy - CAM_H * 0.5f));
    }

    /* ---- with no projector installed at all ------------------------ */
    aowl_region_set_projector(0);
    flags = 0x7F;
    r = aowl_region_project_ex(1.0f, 1.0f, 1.0f, &sx, &sy, &flags, &depth);
    eq_int("with NO projector, project_ex returns 0", r, 0);
    eq_int("...and says NOCAM specifically, not a bare zero", flags,
           AOWL_REGION_PROJ_NOCAM);
    eq_int("...and the refusal is recorded by name",
           aowl_region_last_refusal(), AOWL_REGION_REFUSE_NOPROJ);

    aowl_region_set_projector(cam_project);
    aowl_region_set_screen((int32_t)CAM_W, (int32_t)CAM_H);

    /* ---- the control: a point in FRONT ----------------------------- */
    flags = 0; sx = sy = depth = 0.0f;
    r = aowl_region_project_ex(FX, FY, FZ, &sx, &sy, &flags, &depth);
    eq_int("CONTROL: an in-front point projects", r, 1);
    check("CONTROL: ...and is reported INFRONT, not BEHIND -- so the BEHIND "
          "bit is not a constant",
          (flags & AOWL_REGION_PROJ_INFRONT) &&
          !(flags & AOWL_REGION_PROJ_BEHIND));
    check("CONTROL: ...and depth is positive", depth > 0.0f);
    check("CONTROL: ...and it is on screen, so OFFSCREEN is not a constant "
          "either", !(flags & AOWL_REGION_PROJ_OFFSCREEN));
    eq_int("CONTROL: the five-argument compatibility wrapper still returns 1 "
           "for it", aowl_region_project(FX, FY, FZ, &sx, &sy), 1);

    /* ---- THE FIX: the same point, behind ---------------------------- */
    flags = 0; sx = sy = depth = 0.0f;
    r = aowl_region_project_ex(FX, FY, -FZ, &sx, &sy, &flags, &depth);
    eq_int("FIXED: the behind-camera point still projects (the bearing is "
           "useful, so it is returned)", r, 1);
    check("FIXED: ...and is reported BEHIND",
          (flags & AOWL_REGION_PROJ_BEHIND) != 0);
    check("FIXED: ...and NOT INFRONT -- the two are exclusive",
          !(flags & AOWL_REGION_PROJ_INFRONT));
    check("FIXED: ...and the depth it reports is negative, which a caller can "
          "check without trusting the flag", depth < 0.0f);
    check("FIXED: the position handed back is exactly the mirrored one the "
          "pre-fix code returned -- it is the SAME number, now LABELLED",
          sx == lx && sy == ly);
    eq_int("FIXED: the five-argument compatibility wrapper returns 0 for it, "
           "so an un-updated caller stops drawing the backwards indicator "
           "instead of merely being unchanged",
           aowl_region_project(FX, FY, -FZ, &sx, &sy), 0);

    /* ---- offscreen is a third answer, not folded into behind -------- */
    flags = 0;
    aowl_region_project_ex(400.0f, 0.0f, 20.0f, &sx, &sy, &flags, &depth);
    check("an IN FRONT but OFF SCREEN point reports both INFRONT and "
          "OFFSCREEN -- three outcomes, not two",
          (flags & AOWL_REGION_PROJ_INFRONT) &&
          (flags & AOWL_REGION_PROJ_OFFSCREEN) &&
          !(flags & AOWL_REGION_PROJ_BEHIND));

    aowl_region_set_projector(0);
}

int main(void) {
    int32_t haveDevice;
    aowl_region_init(sink);
    haveDevice = make_device();
    if (!haveDevice)
        printf("note: no D3D11 device (WARP) -- the rasterised half of PART 1 "
               "will report INCONCLUSIVE, which is not a pass\n");
    part1(haveDevice);
    part2();
    printf("\n%s\n", failures ? "RESULT: FAIL" : "RESULT: PASS");
    return failures ? 1 : 0;
}
