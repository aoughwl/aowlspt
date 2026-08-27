/* overlayhost.c -- a D3D11 application that stands in for Tarkov.
 *
 * The overlay hooks `IDXGISwapChain::Present`. Nothing about that is specific
 * to Tarkov: any process with a D3D11 swap chain exercises the same code, so
 * this host creates a window, a device and a swap chain, renders a scene, and
 * presents in a loop. Everything the overlay does inside the game happens here
 * too -- vtable capture, detour install, first-frame device binding, the draw,
 * the state restore, ResizeBuffers, the window subclass and the input path.
 *
 * Three things it is built to prove, rather than merely exercise:
 *
 *  1. **The state restore is real.** The scene's pipeline state is set ONCE,
 *     before the loop, and every frame after that is only Clear + Draw. If the
 *     overlay failed to put back the input layout, the shaders, the blend
 *     state or the vertex buffer, the scene would stop drawing on frame 2. On
 *     top of that, a fingerprint of the context state is taken before and after
 *     each Present and compared, so a mismatch is a failed assertion rather
 *     than something you have to notice by eye.
 *
 *  2. **The pixels are correct.** `--shot` reads the back buffer after Present
 *     into a staging texture and writes a BMP. That is why the swap chain uses
 *     DXGI_SWAP_EFFECT_SEQUENTIAL with one buffer -- under DISCARD the back
 *     buffer contents after Present are undefined and the capture would be
 *     whatever the driver felt like.
 *
 *  3. **Resize does not break anything.** ResizeBuffers is called mid-run and
 *     its HRESULT is checked. Without the overlay releasing its render target
 *     view first this returns DXGI_ERROR_INVALID_CALL, which is the single most
 *     common way an overlay breaks a game.
 *
 * Build:  aowl build (or see README.md in host/Aowlspt.Overlay)
 * Run:    overlayhost.exe --headless --shot shots\    (CI)
 *         overlayhost.exe                             (interactive; INSERT)
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#include "aowlspt_overlay.h"

/* `aowlspt_detour.h` declares this: it is the dispatcher its assembly thunk
 * pool calls when a mod's patch fires, and the client host implements it in
 * nimony. The thunks are emitted whether or not anything uses them, so a
 * standalone C program that includes the detour engine has to satisfy the
 * symbol. The overlay itself never routes through a thunk -- it installs its
 * detours with `aowl_hook_install` and its own C functions -- so this being
 * unreachable is the expected state, not a stub standing in for real work. */
int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

/* Added alongside `aowlspt_nim_patch_fired` when `abi/aowlspt_detour.h` grew a
 * return-side dispatcher: the same rule applies -- the thunk pool is emitted
 * unconditionally, so any binary that includes the engine has to satisfy both
 * symbols. The overlay routes through neither; its detours are C functions with
 * the right signature, installed with `aowl_hook_install`. */
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

static int g_failures = 0;
static void ok(const char* m)  { printf("ok    %s\n", m); }
static void bad(const char* m) { printf("error %s\n", m); g_failures++; }

/* ------------------------------------------------------------------ *
 * The stand-in scene
 * ------------------------------------------------------------------ */

typedef struct SceneVert { float x, y; float r, g, b; } SceneVert;

static const char* kSceneVS =
"struct VIn { float2 p : POSITION; float3 c : COLOR0; };\n"
"struct VOut { float4 p : SV_POSITION; float3 c : COLOR0; };\n"
"VOut main(VIn i) { VOut o; o.p = float4(i.p, 0, 1); o.c = i.c; return o; }\n";
static const char* kScenePS =
"struct VOut { float4 p : SV_POSITION; float3 c : COLOR0; };\n"
"float4 main(VOut i) : SV_Target { return float4(i.c, 1); }\n";

static ID3D11Device*        dev;
static ID3D11DeviceContext* ctx;
static IDXGISwapChain*      swap;
static ID3D11RenderTargetView* rtv;
static ID3D11VertexShader*  svs;
static ID3D11PixelShader*   sps;
static ID3D11InputLayout*   slayout;
static ID3D11Buffer*        svb;
static HWND                 hwnd;
static UINT                 winW = 960, winH = 600;

/* The scene's shaders are compiled at runtime by d3dcompiler because this is a
 * test tool on a developer machine, not code that runs inside the game. The
 * overlay's own shaders are baked; see abi/aowlspt_overlay.h. */
static int compile(const char* src, const char* prof, ID3DBlob** out) {
    typedef HRESULT (WINAPI *Fn)(LPCVOID, SIZE_T, LPCSTR, const void*, void*,
                                 LPCSTR, LPCSTR, UINT, UINT, ID3DBlob**, ID3DBlob**);
    HMODULE m = LoadLibraryA("d3dcompiler_47.dll");
    if (!m) return 0;
    Fn f = (Fn)(void*)GetProcAddress(m, "D3DCompile");
    if (!f) return 0;
    ID3DBlob* errs = NULL;
    HRESULT hr = f(src, strlen(src), "scene", NULL, NULL, "main", prof, 0, 0, out, &errs);
    if (FAILED(hr) && errs)
        printf("      %s\n", (const char*)ID3D10Blob_GetBufferPointer(errs));
    return SUCCEEDED(hr);
}

static int scene_init(void) {
    ID3DBlob *vsb = NULL, *psb = NULL;
    if (!compile(kSceneVS, "vs_4_0", &vsb)) return 0;
    if (!compile(kScenePS, "ps_4_0", &psb)) return 0;
    if (FAILED(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb),
            ID3D10Blob_GetBufferSize(vsb), NULL, &svs))) return 0;
    if (FAILED(ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb),
            ID3D10Blob_GetBufferSize(psb), NULL, &sps))) return 0;

    D3D11_INPUT_ELEMENT_DESC el[2];
    memset(el, 0, sizeof(el));
    el[0].SemanticName = "POSITION";
    el[0].Format = DXGI_FORMAT_R32G32_FLOAT;
    el[1].SemanticName = "COLOR";
    el[1].Format = DXGI_FORMAT_R32G32B32_FLOAT;
    el[1].AlignedByteOffset = 8;
    if (FAILED(ID3D11Device_CreateInputLayout(dev, el, 2,
            ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), &slayout)))
        return 0;

    SceneVert v[3] = {
        { 0.0f,  0.75f, 1.0f, 0.35f, 0.15f },
        { 0.7f, -0.6f,  0.15f, 0.9f, 0.35f },
        {-0.7f, -0.6f,  0.2f, 0.4f, 1.0f },
    };
    D3D11_BUFFER_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = sizeof(v);
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA sd;
    memset(&sd, 0, sizeof(sd));
    sd.pSysMem = v;
    if (FAILED(ID3D11Device_CreateBuffer(dev, &bd, &sd, &svb))) return 0;
    return 1;
}

/* Set once, deliberately never set again: see note 1 in the header comment. */
static void scene_bind(void) {
    UINT stride = sizeof(SceneVert), offset = 0;
    ID3D11DeviceContext_IASetInputLayout(ctx, slayout);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &svb, &stride, &offset);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, svs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, sps, NULL, 0);
    D3D11_VIEWPORT vp;
    vp.TopLeftX = 0; vp.TopLeftY = 0;
    vp.Width = (float)winW; vp.Height = (float)winH;
    vp.MinDepth = 0; vp.MaxDepth = 1;
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
}

/* ------------------------------------------------------------------ *
 * State fingerprint -- the machine-checkable half of "it restores state"
 * ------------------------------------------------------------------ */

typedef struct Print {
    void* layout; void* vb; void* vs; void* ps; void* gs; void* rtv0;
    void* rast; void* blend; void* depth;
    UINT stride, offset;
    D3D11_PRIMITIVE_TOPOLOGY topo;
    D3D11_VIEWPORT vp0;
    UINT vpCount;
} Print;

static void fingerprint(Print* p) {
    memset(p, 0, sizeof(*p));
    ID3D11InputLayout* l = NULL; ID3D11Buffer* b = NULL;
    ID3D11VertexShader* v = NULL; ID3D11PixelShader* s = NULL;
    ID3D11GeometryShader* g = NULL; ID3D11RenderTargetView* r = NULL;
    ID3D11RasterizerState* rs = NULL; ID3D11BlendState* bs = NULL;
    ID3D11DepthStencilState* ds = NULL;
    FLOAT bf[4]; UINT mask = 0, ref = 0;

    ID3D11DeviceContext_IAGetInputLayout(ctx, &l);
    ID3D11DeviceContext_IAGetVertexBuffers(ctx, 0, 1, &b, &p->stride, &p->offset);
    ID3D11DeviceContext_IAGetPrimitiveTopology(ctx, &p->topo);
    ID3D11DeviceContext_VSGetShader(ctx, &v, NULL, NULL);
    ID3D11DeviceContext_PSGetShader(ctx, &s, NULL, NULL);
    ID3D11DeviceContext_GSGetShader(ctx, &g, NULL, NULL);
    ID3D11DeviceContext_OMGetRenderTargets(ctx, 1, &r, NULL);
    ID3D11DeviceContext_RSGetState(ctx, &rs);
    ID3D11DeviceContext_OMGetBlendState(ctx, &bs, bf, &mask);
    ID3D11DeviceContext_OMGetDepthStencilState(ctx, &ds, &ref);
    p->vpCount = 1;
    ID3D11DeviceContext_RSGetViewports(ctx, &p->vpCount, &p->vp0);

    p->layout = l; p->vb = b; p->vs = v; p->ps = s; p->gs = g; p->rtv0 = r;
    p->rast = rs; p->blend = bs; p->depth = ds;

    /* Release immediately: the pointers are compared as identities, and holding
     * the references would make this test leak in exactly the way it is
     * checking the overlay does not. */
    if (l) ID3D11InputLayout_Release(l);
    if (b) ID3D11Buffer_Release(b);
    if (v) ID3D11VertexShader_Release(v);
    if (s) ID3D11PixelShader_Release(s);
    if (g) ID3D11GeometryShader_Release(g);
    if (r) ID3D11RenderTargetView_Release(r);
    if (rs) ID3D11RasterizerState_Release(rs);
    if (bs) ID3D11BlendState_Release(bs);
    if (ds) ID3D11DepthStencilState_Release(ds);
}

static int print_eq(const Print* a, const Print* b) {
    return memcmp(a, b, sizeof(Print)) == 0;
}

/* ------------------------------------------------------------------ *
 * Screenshots
 * ------------------------------------------------------------------ */

static int shoot(const char* path) {
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D, (void**)&bb)))
        return 0;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(bb, &td);
    D3D11_TEXTURE2D_DESC sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    ID3D11Texture2D* stage = NULL;
    if (FAILED(ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage))) {
        ID3D11Texture2D_Release(bb);
        return 0;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stage, (ID3D11Resource*)bb);
    D3D11_MAPPED_SUBRESOURCE map;
    int okFlag = 0;
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stage, 0,
                                          D3D11_MAP_READ, 0, &map))) {
        FILE* f = fopen(path, "wb");
        if (f) {
            UINT w = td.Width, h = td.Height;
            UINT rowBytes = w * 4;
            UINT imgBytes = rowBytes * h;
            uint8_t fh[14] = { 'B','M' };
            uint32_t fsz = 14 + 40 + imgBytes;
            memcpy(fh + 2, &fsz, 4);
            uint32_t off = 54;
            memcpy(fh + 10, &off, 4);
            fwrite(fh, 1, 14, f);
            uint8_t ih[40];
            memset(ih, 0, sizeof(ih));
            uint32_t v32 = 40; memcpy(ih + 0, &v32, 4);
            memcpy(ih + 4, &w, 4);
            memcpy(ih + 8, &h, 4);
            uint16_t v16 = 1; memcpy(ih + 12, &v16, 2);
            v16 = 32; memcpy(ih + 14, &v16, 2);
            memcpy(ih + 20, &imgBytes, 4);
            fwrite(ih, 1, 40, f);
            /* BMP rows run bottom-up, and the back buffer is R8G8B8A8 while BMP
             * wants BGRA, so both the row order and two channels are swapped. */
            uint8_t* row = (uint8_t*)malloc(rowBytes);
            for (int y = (int)h - 1; y >= 0; y--) {
                const uint8_t* src = (const uint8_t*)map.pData + (size_t)y * map.RowPitch;
                for (UINT x = 0; x < w; x++) {
                    row[x * 4 + 0] = src[x * 4 + 2];
                    row[x * 4 + 1] = src[x * 4 + 1];
                    row[x * 4 + 2] = src[x * 4 + 0];
                    row[x * 4 + 3] = 255;
                }
                fwrite(row, 1, rowBytes, f);
            }
            free(row);
            fclose(f);
            okFlag = 1;
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stage, 0);
    }
    ID3D11Texture2D_Release(stage);
    ID3D11Texture2D_Release(bb);
    return okFlag;
}

/* Counts pixels that are neither the clear colour nor the scene's triangle --
 * a cheap "did the overlay actually put pixels on the screen" check that does
 * not need a human to look at the BMP. The panel's background is a dark
 * near-black with a light blue border, so the border pixels are what this
 * finds. */
static int count_overlay_pixels(void) {
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D, (void**)&bb)))
        return -1;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(bb, &td);
    D3D11_TEXTURE2D_DESC sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    ID3D11Texture2D* stage = NULL;
    if (FAILED(ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage))) {
        ID3D11Texture2D_Release(bb);
        return -1;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stage, (ID3D11Resource*)bb);
    D3D11_MAPPED_SUBRESOURCE map;
    int n = -1;
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stage, 0,
                                          D3D11_MAP_READ, 0, &map))) {
        n = 0;
        /* The panel sits at x=40,y=60. Sample its title bar, well inside it. */
        for (UINT y = 62; y < 84 && y < td.Height; y++) {
            const uint8_t* src = (const uint8_t*)map.pData + (size_t)y * map.RowPitch;
            for (UINT x = 42; x < 42 + 500 && x < td.Width; x++) {
                uint8_t r = src[x * 4 + 0], g = src[x * 4 + 1], b = src[x * 4 + 2];
                /* The title bar is RGB(28,34,44) over the clear colour; text is
                 * near-white. Anything that dark or that bright is ours. */
                if ((r < 60 && g < 70 && b < 80) || (r > 200 && g > 200 && b > 200))
                    n++;
            }
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stage, 0);
    }
    ID3D11Texture2D_Release(stage);
    ID3D11Texture2D_Release(bb);
    return n;
}

/* ------------------------------------------------------------------ *
 * Reading the panel back
 *
 * The BMPs prove the panel drew; they do not prove *what* it drew, and the one
 * thing a screenshot is worst at is a line of text that is two characters
 * short of what it should say. So this decodes the back buffer back into
 * characters, against `aowl_ov_font` -- the same 8x16 table the overlay
 * uploads -- and hands the caller a string it can `strstr`.
 *
 * It is exact, not approximate. The font is sampled POINT/CLAMP at one texel
 * per pixel and a glyph texel is opaque, so a lit pixel is the text colour
 * itself and the 16 bytes a cell decodes to either equal a glyph's bytes or do
 * not. Nothing is scaled: the caller checks `aowl_ov_scale() == 1` first.
 * ------------------------------------------------------------------ */

#define OCR_BLANK_RUN 4     /* blank cells that end a run; the legend uses 3 */
#define OCR_MIN_RUN   6     /* glyphs before a run counts as a line of text */

/* Every run of text drawn in `col`, one per line, in the order they appear
 * down the screen.
 *
 * Whitespace is collapsed to single spaces, so that a caller can compare
 * against the source string regardless of where a wrap fell: `aowl_ov_wrap`
 * breaks on a space and drops it, so a wrapped sentence and its unwrapped self
 * differ only in runs of spaces.
 *
 * The scan is every pixel column, not every eighth: the panel draws text at
 * the left margin, centred on tabs and right-aligned on the title bar, and the
 * title bar is where the frame cost is. A run that starts on the wrong
 * alignment dies on its first cell -- eight columns of two different glyphs do
 * not spell a third -- so the misaligned starts cost time and produce nothing.
 */
/* WHERE a decoded run is, in back-buffer pixels. `panel_read_text` throws this
 * away, which is fine for "is this string on screen" and useless for "is this\n * row indented further than that one" -- and indentation is the whole of the
 * hierarchy question. So the scan optionally records one of these per run.
 *
 * Recorded, not derived: the x here is the pixel column the glyphs were
 * actually decoded at. Computing it from AOWL_OV_PAD and a depth would be a
 * second derivation of the thing under test, which is how this harness already
 * once reported a button-geometry drift that did not exist. */
typedef struct OcrRun { int x, y; int at; } OcrRun;

static OcrRun* g_ocrRuns = NULL;
static int     g_ocrRunCap = 0;
static int     g_ocrRunN = 0;

static int panel_read_text(char* out, int cap, uint32_t col) {
    ID3D11Texture2D* bb = NULL;
    D3D11_TEXTURE2D_DESC td, sd;
    ID3D11Texture2D* stage = NULL;
    D3D11_MAPPED_SUBRESOURCE map;
    uint8_t* lit = NULL;
    int n = 0;
    if (cap > 0) out[0] = 0;
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D, (void**)&bb)))
        return 0;
    ID3D11Texture2D_GetDesc(bb, &td);
    sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    if (FAILED(ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage))) {
        ID3D11Texture2D_Release(bb);
        return 0;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stage, (ID3D11Resource*)bb);
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stage, 0,
                                          D3D11_MAP_READ, 0, &map))) {
        const uint8_t* base = (const uint8_t*)map.pData;
        UINT W = td.Width, H = td.Height, ux, uy;
        uint8_t want[3];
        want[0] = (uint8_t)(col & 0xFF);
        want[1] = (uint8_t)((col >> 8) & 0xFF);
        want[2] = (uint8_t)((col >> 16) & 0xFF);
        lit = (uint8_t*)malloc((size_t)W * H);
        if (lit) {
            /* One pass for "is this pixel the text colour", so the run scan is
             * table lookups. The font is sampled POINT/CLAMP at one texel per
             * pixel onto integer positions and a glyph texel is opaque, so a
             * lit pixel is the text colour exactly; one step of tolerance per
             * channel and no more, because a near miss would mean the sampler
             * is filtering, which is itself worth failing on. */
            for (uy = 0; uy < H; uy++) {
                const uint8_t* src = base + (size_t)uy * map.RowPitch;
                uint8_t* dst = lit + (size_t)uy * W;
                for (ux = 0; ux < W; ux++) {
                    const uint8_t* q = src + (size_t)ux * 4;
                    dst[ux] = (uint8_t)(q[0] + 1 >= want[0] && q[0] <= want[0] + 1 &&
                                        q[1] + 1 >= want[1] && q[1] <= want[1] + 1 &&
                                        q[2] + 1 >= want[2] && q[2] <= want[2] + 1);
                }
            }
            for (uy = 0; (int)uy + AOWL_OV_CH <= (int)H; uy++) {
                for (ux = 0; (int)ux + AOWL_OV_CW <= (int)W; ux++) {
                    char line[512];
                    int len = 0, blanks = 0, cells = 0;
                    int firstGlyphX = -1;
                    UINT cx = ux;
                    while ((int)cx + AOWL_OV_CW <= (int)W) {
                        uint8_t rows[AOWL_OV_CH];
                        int r, b, g, blank = 1, hit = -1;
                        for (r = 0; r < AOWL_OV_CH; r++) {
                            const uint8_t* row = lit + (size_t)(uy + r) * W + cx;
                            uint8_t bits = 0;
                            for (b = 0; b < AOWL_OV_CW; b++)
                                if (row[b]) bits |= (uint8_t)(0x80u >> b);
                            rows[r] = bits;
                            if (bits) blank = 0;
                        }
                        if (blank) {
                            if (++blanks >= OCR_BLANK_RUN) break;
                        } else {
                            for (g = 0; g < 95; g++)
                                if (memcmp(rows, aowl_ov_font[g], AOWL_OV_CH) == 0) {
                                    hit = g;
                                    break;
                                }
                            if (hit < 0) break;
                            if (firstGlyphX < 0) firstGlyphX = (int)cx;
                            if (blanks && len && len < (int)sizeof(line) - 1)
                                line[len++] = ' ';
                            blanks = 0;
                            if (len < (int)sizeof(line) - 1)
                                line[len++] = (char)(32 + hit);
                        }
                        cells++;
                        cx += AOWL_OV_CW;
                    }
                    line[len] = 0;
                    if (len >= OCR_MIN_RUN && n + len + 2 < cap) {
                        if (g_ocrRuns && g_ocrRunN < g_ocrRunCap) {
                            /* The first GLYPH, not the scan start.
                             *
                             * The scan walks one pixel at a time and a run is
                             * happily begun up to OCR_BLANK_RUN-1 blank cells
                             * before the text -- blanks only end a run once
                             * four of them are seen, and a leading blank adds
                             * no character. So `ux` is the leftmost position
                             * the decoder HAPPENED to start from, which is up
                             * to three cells (24 px) left of the ink, and the
                             * amount of that error depends on what is drawn
                             * next to the text.
                             *
                             * That is a measuring instrument that is quietly
                             * wrong by a variable amount, and it produced its
                             * first false reading immediately: a row label
                             * drawn 4 px right of a group header measured
                             * 20 px LEFT of it, because the header had a solid
                             * accent bar beside it that broke the early scans
                             * and the row had nothing. Every indentation claim
                             * in this file rests on this number, so it is the
                             * ink`s position or it is nothing. */
                            g_ocrRuns[g_ocrRunN].x = firstGlyphX >= 0
                                                       ? firstGlyphX : (int)ux;
                            g_ocrRuns[g_ocrRunN].y = (int)uy;
                            g_ocrRuns[g_ocrRunN].at = n;
                            g_ocrRunN++;
                        }
                        memcpy(out + n, line, (size_t)len);
                        n += len;
                        out[n++] = '\n';
                        out[n] = 0;
                        /* Past what this run consumed. Two runs one pixel
                         * apart would otherwise both be recorded and the
                         * buffer would fill with near-duplicates. */
                        ux += (UINT)(cells * AOWL_OV_CW) - 1;
                    }
                }
            }
            free(lit);
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stage, 0);
    }
    ID3D11Texture2D_Release(stage);
    ID3D11Texture2D_Release(bb);
    return n;
}

/* WARNING, not a silent cut. `panel_read_text` stops at `cap`, and a caller
 * that then reports "the legend is not on screen" has turned INCONCLUSIVE into
 * FAIL -- which is exactly what happened the first time the launch hint added
 * two lines above the legend: the buffer filled before the scan reached the
 * bottom of the panel and the legend check reported a defect that was not
 * there. Every read now says when it came back full. */
static int panel_read_text_capped(char* out, int cap, uint32_t col,
                                  const char* what) {
    int n = panel_read_text(out, cap, col);
    if (n >= cap - 64)
        printf("      WARNING %s: the OCR buffer came back full (%d of %d "
               "bytes) -- anything below this point was NOT looked at, so a "
               "`not on screen` verdict from it is INCONCLUSIVE\n",
               what, n, cap);
    return n;
}


/* The pixel column the run CONTAINING `needle` was decoded at, in the text
 * drawn in `col`. -1 when nothing on screen contains it -- which the caller
 * must treat as INCONCLUSIVE, not as "it is at x=0".
 *
 * `nth` picks among several matches, top to bottom, because a tree draws the
 * same word at more than one depth. */
static int panel_text_x(uint32_t col, const char* needle, int nth, int* outY) {
    static OcrRun runs[512];
    static char buf[65536];
    int i, seen = 0, n;
    g_ocrRuns = runs; g_ocrRunCap = 512; g_ocrRunN = 0;
    n = panel_read_text(buf, (int)sizeof(buf), col);
    g_ocrRuns = NULL;
    if (n >= (int)sizeof(buf) - 64)
        printf("      WARNING panel_text_x(%s): the OCR buffer came back full "
               "-- a miss below this point is INCONCLUSIVE\n", needle);
    for (i = 0; i < g_ocrRunN; i++) {
        const char* line = buf + runs[i].at;
        const char* end = strchr(line, (int)0x0A);
        size_t len = end ? (size_t)(end - line) : strlen(line);
        char one[512];
        if (len > sizeof(one) - 1) len = sizeof(one) - 1;
        memcpy(one, line, len); one[len] = 0;
        if (strstr(one, needle)) {
            if (seen++ < nth) continue;
            if (outY) *outY = runs[i].y;
            return runs[i].x;
        }
    }
    if (outY) *outY = -1;
    return -1;
}

/* The one line of `buf` that contains `needle`, copied into `out`. NULL when
 * no line does. */
static const char* read_line_with(const char* buf, const char* needle,
                                  char* out, int cap) {
    const char* at = strstr(buf, needle);
    const char* s;
    const char* e;
    int len;
    if (!at) return NULL;
    for (s = at; s > buf && s[-1] != '\n'; s--) { }
    for (e = at; *e && *e != '\n'; e++) { }
    len = (int)(e - s);
    if (len > cap - 1) len = cap - 1;
    memcpy(out, s, (size_t)len);
    out[len] = 0;
    return out;
}

/* The frame cost on the title bar, read back the same way.
 *
 * `avgNs` and `maxNs` are deliberately not cleared when the panel closes -- a
 * player wants the cost of the panel they had open in a raid, and zeroing on
 * close would answer that with 0 -- so a reopened panel puts the previous
 * opening's numbers on its title bar. The overlay labels them `was` until this
 * opening has put `AOWL_OV_COST_SETTLE` frames into the average.
 *
 * Both halves are checked, and the second is the one that matters: a label
 * that never came down would pass the first check and would be a lie for the
 * rest of the raid.
 */
static int check_cost_label(int wantWas) {
    static char faint[16384];
    char line[512];
    char m[256];
    if (aowl_ov_scale() != 1) return 1;
    panel_read_text(faint, (int)sizeof(faint), AOWL_OV_FAINT);
    if (!read_line_with(faint, " us peak ", line, (int)sizeof(line))) {
        bad("no frame cost on the title bar to read");
        return 0;
    }
    if (wantWas && !strstr(line, "was ")) {
        _snprintf(m, sizeof(m), "the reopened panel shows `%s` -- the previous "
                  "opening's average, unlabelled", line);
        m[sizeof(m) - 1] = 0;
        bad(m);
        return 0;
    }
    if (!wantWas && strstr(line, "was ")) {
        _snprintf(m, sizeof(m), "the frame cost is still labelled `was` long "
                  "after the panel reopened: `%s`", line);
        m[sizeof(m) - 1] = 0;
        bad(m);
        return 0;
    }
    _snprintf(m, sizeof(m), "the title bar reads `%s` %s the reopen", line,
              wantWas ? "just after" : "well after");
    m[sizeof(m) - 1] = 0;
    ok(m);
    return 1;
}

/* The legend, read back off the screen rather than assumed.
 *
 * This is the check that the marker legend is *whole*. It used to be printed
 * with `aowl_ov_textn`, which clips: 106 characters into the 57 columns the
 * 480-wide floor leaves is the legend cut in half, and the half it loses is
 * the markers a new player has not learnt. Run this host with
 * `--size 520x400` and the panel is at that floor.
 *
 * The strings below are literals on purpose. Deriving them from the header
 * would make this a check that the header agrees with itself. */
static int check_legend(void)
{
    static const char* kMarkers =
        "* your override ~ asked, no answer yet ! game disagrees "
        "ON*/OFF* takes a restart dim = not running";
    static const char* kKeysHead =
        "TAB view UP/DN move SPACE toggle C clear F filter [";
    static const char* kKeysTail = "] A apply R reload INS/ESC close";
    static char faint[65536], text[65536];
    int good = 1;
    char m[256];

    if (aowl_ov_scale() != 1) {
        printf("      legend readback skipped: the panel is drawn at %dx\n",
               aowl_ov_scale());
        return 1;
    }
    /* `aowl_ov_build` clamps the panel to 480x220 and does not shrink past it,
     * so a window smaller than the panel's origin plus that floor gets a panel
     * that hangs off the edge -- the legend is then missing from the back
     * buffer because it was never inside it, which is a different fact from
     * the one this checks. Said out loud rather than skipped quietly. */
    if ((int)winW < AOWL_OV_PANEL_X + 480 || (int)winH < AOWL_OV_PANEL_Y + 220) {
        printf("      legend readback skipped: a %ux%u window is smaller than "
               "the panel's 480x220 floor at %d,%d, so the legend is off the "
               "back buffer rather than clipped in it\n",
               winW, winH, AOWL_OV_PANEL_X, AOWL_OV_PANEL_Y);
        return 1;
    }
    panel_read_text_capped(faint, (int)sizeof(faint), AOWL_OV_FAINT, "legend/faint");
    panel_read_text_capped(text, (int)sizeof(text), AOWL_OV_TEXT, "legend/text");
    /* Wrapped lines are separate lines on screen and one sentence in the
     * legend, so the newlines go before the compare. */
    { char* q; for (q = faint; *q; q++) if (*q == '\n') *q = ' '; }
    { char* q; for (q = text;  *q; q++) if (*q == '\n') *q = ' '; }

    if (strstr(faint, kMarkers)) {
        _snprintf(m, sizeof(m),
                  "the whole marker legend reads back off the back buffer, "
                  "all %d characters of it, in a %ux%u window",
                  (int)strlen(kMarkers), winW, winH);
        m[sizeof(m) - 1] = 0;
        ok(m);
    } else {
        bad("the marker legend is not on screen in full -- it was clipped or "
            "it did not draw");
        printf("      wanted: %s\n", kMarkers);
        printf("      faint text read back:\n%s\n", faint);
        good = 0;
    }
    if (strstr(text, kKeysHead) && strstr(text, kKeysTail))
        ok("the key legend is on screen from `TAB view` to `INS/ESC close`");
    else {
        bad("the key legend is not on screen in full");
        printf("      text read back:\n%s\n", text);
        good = 0;
    }
    return good;
}


/* ------------------------------------------------------------------ *
 * The settings screen: group titles, the tree, the breadcrumb, search
 *
 * Every assertion below is on the FINISHED STATE and most of them are
 * NEGATIVE, because a negative can be falsified and a self-comparison cannot.
 * Two instruments, deliberately, and they answer different questions:
 *
 *   * `aowl_ov_cats_wellformed` reads the built table. It settles "no group is\n *     nameless" and "no node is unreachable by breadcrumb" for every node,
 *     including the ones scrolled off screen -- which OCR cannot see.
 *   * `panel_read_text` reads the BACK BUFFER. It settles what the player
 *     actually sees. A structural pass with nothing on screen is exactly the
 *     "the element exists / activeSelf is true" trap, so the structural check
 *     never stands alone: every claim below is paired with a rendered one.
 *
 * INCONCLUSIVE is a third outcome and is reported as such: if the page never
 * loaded there is nothing to read back, and saying PASS then would be a lie.
 * ------------------------------------------------------------------ */

static int g_setPage = -1;     /* the nav index of aowl.deep, once found */

/* PASS/FAIL/INCONCLUSIVE for the group titles, read off the SCREEN. */
static int check_group_titles(void) {
    static char accent[65536];
    static char text[65536];
    char why[192];
    int structural;
    if (g_ov.sItemCount <= 0) {
        printf("INCONCLUSIVE group titles: no page loaded (%d rows)\n",
               g_ov.sItemCount);
        return 0;
    }
    structural = aowl_ov_cats_wellformed(why, (int)sizeof(why));
    if (!structural) { printf("error nav tree malformed: %s\n", why); return 0; }

    panel_read_text(accent, (int)sizeof(accent), AOWL_OV_ACCENT);
    panel_read_text(text, (int)sizeof(text), AOWL_OV_TEXT);
    /* The header of a group at depth 3 has to be ON SCREEN, by name. Before
     * this change the group boundary was a hairline and this string was
     * nowhere in the back buffer -- which is the check failing on the old
     * code, i.e. the mutation proof for it. */
    if (!strstr(accent, "Health > Regeneration") &&
        !strstr(accent, "Regeneration")) {
        printf("error no group title rendered: the pane draws separators but "
               "no group NAME (looked for `Regeneration` in the accent runs)\n");
        return 0;
    }
    /* NEGATIVE: the fixture's last row declares no path at all, and it must
     * still land under a named group -- the table must contain no empty
     * label, which `cats_wellformed` above already refuses, AND a `General`
     * group must exist for it rather than a blank one. */
    {
        int i, found = 0;
        for (i = 0; i < g_ov.catCount; i++)
            if (strcmp(g_ov.cats[i].label, "General") == 0) found = 1;
        if (!found) {
            printf("error the row that declared no group got no named group\n");
            return 0;
        }
    }
    (void)text;
    return 1;
}

/* The breadcrumb, read off the screen, after the nav has been driven into a
 * depth-3 node. */
static int check_breadcrumb(void) {
    static char dim[65536];
    static char text[65536];
    int tailX, ancX;
    if (g_ov.selCat < 0 || g_ov.selCat >= g_ov.sCatCount) {
        printf("INCONCLUSIVE breadcrumb: no group is selected\n");
        return 0;
    }
    /* The ANCESTORS are dim and the CURRENT segment is bright, and both facts
     * are read off the back buffer rather than off the draw calls.
     *
     * This is a stronger claim than "the path is on screen": a crumb rendered
     * in one flat colour passes a substring test and still leaves the player
     * hunting for which end says where they are. The split IS the change, so
     * the check is on the split. */
    panel_read_text_capped(dim, (int)sizeof(dim), AOWL_OV_DIM, "crumb/dim");
    panel_read_text_capped(text, (int)sizeof(text), AOWL_OV_TEXT, "crumb/text");
    if (!strstr(dim, "Deep tree fixture > Player")) {
        printf("error the breadcrumb ancestors are not on screen dimmed -- "
               "expected `Deep tree fixture > Player` in the DIM runs\n");
        return 0;
    }
    if (!strstr(text, "> Health")) {
        printf("error the breadcrumb`s CURRENT segment is not drawn in the "
               "bright colour -- expected `> Health` in the TEXT runs\n");
        return 0;
    }
    /* ...and the bright tail comes AFTER the dim ancestors, which is what
     * makes it a trail rather than two unrelated labels. */
    ancX = panel_text_x(AOWL_OV_DIM, "Deep tree fixture > Player", 0, NULL);
    tailX = panel_text_x(AOWL_OV_TEXT, "> Health", 0, NULL);
    if (ancX < 0 || tailX < 0) {
        printf("INCONCLUSIVE breadcrumb order: one half did not decode "
               "(ancestors x=%d, tail x=%d)\n", ancX, tailX);
        return 0;
    }
    if (tailX <= ancX) {
        printf("error the breadcrumb tail renders at x=%d, at or before its "
               "own ancestors at x=%d -- it is not a trail\n", tailX, ancX);
        return 0;
    }
    return 1;
}

/* IS THE DEPTH VISIBLE? Measured as pixels of indentation ON SCREEN, because
 * that is the only form of the question the player can answer.
 *
 * `Regeneration` sits one level below `Health`, which sits one below `Player`.
 * Each must render strictly further right than the last -- AND each is read
 * from a different text colour, which is the depth-in-colour claim making
 * itself falsifiable: if every level were drawn in one colour, two of these
 * three reads would come back -1 and the check would say INCONCLUSIVE rather
 * than quietly pass. */
static int check_depth_visible(void) {
    int xPlayer, xHealth, xRegen;
    if (g_ov.selCat >= 0) {
        printf("INCONCLUSIVE nav depth: a node is selected, so the active-path "
               "colouring is in play and the colours no longer encode depth "
               "alone -- run this with nothing selected\n");
        return 0;
    }
    xPlayer = panel_text_x(AOWL_OV_TEXT, "Player", 0, NULL);
    xHealth = panel_text_x(AOWL_OV_DIM, "Health", 0, NULL);
    xRegen  = panel_text_x(AOWL_OV_FAINT, "Regeneration", 0, NULL);
    if (xPlayer < 0 || xHealth < 0 || xRegen < 0) {
        printf("INCONCLUSIVE nav depth: one level did not decode "
               "(Player x=%d, Health x=%d, Regeneration x=%d)\n",
               xPlayer, xHealth, xRegen);
        return 0;
    }
    if (!(xHealth > xPlayer && xRegen > xHealth)) {
        printf("error the nav does not indent by depth on screen: "
               "Player x=%d, Health x=%d, Regeneration x=%d\n",
               xPlayer, xHealth, xRegen);
        return 0;
    }
    printf("      nav indent, measured on the back buffer: depth1 x=%d "
           "depth2 x=%d depth3 x=%d, each in its own colour\n",
           xPlayer, xHealth, xRegen);
    return 1;
}

/* Like `panel_text_x`, but only inside the NAV COLUMN.
 *
 * Needed because the same words appear in three places: the nav, the group
 * band, and the detail strip`s breadcrumb. "Did collapsing hide `Health`"
 * asked of the WHOLE screen is answered by the detail strip, which is not the
 * nav and never collapses -- so the unscoped question is unanswerable and the
 * answer it gives is wrong. */
static int nav_text_x_y(uint32_t col, const char* needle, int* outY) {
    float prx = 0.0f;
    int nth, x;
    aowl_ov_panel_rect(&prx, NULL, NULL, NULL);
    for (nth = 0; nth < 16; nth++) {
        x = panel_text_x(col, needle, nth, outY);
        if (x < 0) return -1;
        /* The nav column is AOWL_OV_PAD + 256 wide and the right pane starts
         * at +278, so 272 is inside the nav and short of the pane. 300 was
         * NOT: it reached past 318 and let the right pane`s group bands answer
         * questions asked about the nav. */
        if (x < (int)prx + 272) return x;
    }
    return -1;
}

static int nav_text_x(uint32_t col, const char* needle) {
    return nav_text_x_y(col, needle, NULL);
}

/* WHERE AM I? The negative the report asked for, and it is the strong form:
 * NO nav node other than the selected one may render as selected.
 *
 * "Selected" is a solid 3px accent bar spanning the full row height at the
 * nav`s left edge. Ancestors get a SHORT bar in a different colour and the
 * rest get none, so counting full-height accent bars in that column counts
 * selected rows -- and the answer must be exactly one.
 *
 * Counted off the back buffer, not off `selCat`: `selCat` is the thing under
 * test. Clicking a leaf used to leave the ROOT looking selected, and any check
 * phrased against `selCat` would have passed while the screen was wrong. */
static int count_selected_bars(int navX, uint32_t col, int yMin, int* firstY) {
    ID3D11Texture2D* bb = NULL;
    D3D11_TEXTURE2D_DESC td, sd;
    ID3D11Texture2D* stage = NULL;
    D3D11_MAPPED_SUBRESOURCE map;
    int found = 0, run = 0, y;
    uint8_t want[3];
    if (firstY) *firstY = -1;
    /* The SAME byte order `panel_read_text` uses, copied rather than re-derived
     * from AOWL_RGBA -- deriving it independently is how this first came back
     * "0 nav rows are selected" about a bar that was plainly on screen. */
    want[0] = (uint8_t)(col & 0xFF);
    want[1] = (uint8_t)((col >> 8) & 0xFF);
    want[2] = (uint8_t)((col >> 16) & 0xFF);
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D,
                                        (void**)&bb)))
        return -1;
    ID3D11Texture2D_GetDesc(bb, &td);
    sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    if (FAILED(ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage))) {
        ID3D11Texture2D_Release(bb);
        return -1;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stage,
                                     (ID3D11Resource*)bb);
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stage, 0,
                                          D3D11_MAP_READ, 0, &map))) {
        const uint8_t* base = (const uint8_t*)map.pData;
        for (y = yMin; y < (int)td.Height; y++) {
            const uint8_t* q = base + (size_t)y * map.RowPitch
                                    + (size_t)navX * 4;
            int on = q[0] + 1 >= want[0] && q[0] <= want[0] + 1 &&
                     q[1] + 1 >= want[1] && q[1] <= want[1] + 1 &&
                     q[2] + 1 >= want[2] && q[2] <= want[2] + 1;
            if (on) { run++; continue; }
            /* A FULL-height bar is the selection; the ancestors` ticks are
             * AOWL_OV_ROW_H-10 tall and a different colour, so neither the
             * length nor the colour of one can be mistaken for the other. */
            if (run >= AOWL_OV_ROW_H - 2) {
                if (found == 0 && firstY) *firstY = y - run;
                found++;
            }
            run = 0;
        }
        if (run >= AOWL_OV_ROW_H - 2) {
            if (found == 0 && firstY) *firstY = (int)td.Height - run;
            found++;
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stage, 0);
    }
    ID3D11Texture2D_Release(stage);
    ID3D11Texture2D_Release(bb);
    return found;
}

static int check_one_selected(const char* wantLabel) {
    float prx = 0.0f, pry = 0.0f;
    int n, selY = -1, lblY = -1, lblX;
    aowl_ov_panel_rect(&prx, &pry, NULL, NULL);
    /* The row HIGHLIGHT, sampled in the middle of the nav column rather than
     * the 3px accent bar at its edge -- the same claim, and it does not rest
     * on a three-pixel rectangle surviving everything drawn over it. 150 units
     * in is inside every nav row, and the scan starts BELOW the header --
     * without which the `SETTINGS` tab, which wears the same colour because it
     * is also "the selected one", counts as a selected nav row. It did. */
    n = count_selected_bars((int)prx + 150, AOWL_OV_SELBG,
                            (int)pry + AOWL_OV_HEAD_H, &selY);
    if (n < 0) {
        printf("INCONCLUSIVE selection: could not read the back buffer\n");
        return 0;
    }
    if (n != 1) {
        printf("error %d nav rows render as selected, not 1 -- the tree does "
               "not show where you are\n", n);
        return 0;
    }
    /* ...and it is the row that was CLICKED, not its root. Matched by the
     * label`s own y against the bar`s y. */
    /* IN THE NAV, not anywhere. The breadcrumb in the right pane says
     * `... > Health` in the same colour and sits at the top of the body, so an
     * unscoped read answers this question with the header and reports that
     * something else is highlighted. */
    lblX = nav_text_x_y(AOWL_OV_TEXT, wantLabel, &lblY);
    if (lblX < 0) {
        printf("INCONCLUSIVE selection: `%s` is not on screen to compare "
               "against\n", wantLabel);
        return 0;
    }
    if (lblY < selY || lblY > selY + AOWL_OV_ROW_H) {
        printf("error the selected row is at y=%d but `%s` renders at y=%d -- "
               "something else is highlighted\n", selY, wantLabel, lblY);
        return 0;
    }
    printf("      selection, measured on the back buffer: exactly 1 selected "
           "row, at y=%d, carrying `%s`\n", selY, wantLabel);
    return 1;
}

/* COLLAPSE ACTUALLY HIDES. The negative: after closing a branch, none of its
 * children may still be on screen. Asserted on the glyphs, because a tree that
 * flips a flag and keeps drawing the children is exactly the bug. */
static int check_collapse_hides(void) {
    int before = nav_text_x(AOWL_OV_FAINT, "Regeneration");
    if (before < 0) {
        printf("INCONCLUSIVE collapse: `Regeneration` was not on screen "
               "BEFORE the branch was closed, so hiding it proves nothing\n");
        return -1;
    }
    return 1;
}

/* IS THE SEARCH BOX BIG? Measured, not asserted. The field`s own label is a
 * sentence that only fits when the box spans the pane, and the box`s HEIGHT is
 * the gap between that label and the scope line under it. */
static int check_search_prominent(void) {
    static char faint[65536];
    int inputY = -1, scopeY = -1;
    panel_read_text_capped(faint, (int)sizeof(faint), AOWL_OV_FAINT,
                           "searchbox");
    if (!strstr(faint, "search these settings by name, key or group")) {
        printf("error the search field`s own label is not on screen in full -- "
               "the box is too narrow to hold it\n");
        return 0;
    }
    /* The scope line names the three fields it searches. The parenthetical
     * about what it does NOT search is dropped on a narrow pane -- deliberately,
     * see the overlay`s own comment -- so the check is on the part that is
     * always said, not on the part that is a nicety. */
    if (!strstr(faint, "name, key, group only")) {
        printf("error the search SCOPE line does not say what it searched\n");
        return 0;
    }
    (void)panel_text_x(AOWL_OV_FAINT, "search these settings by name", 0,
                       &inputY);
    (void)panel_text_x(AOWL_OV_FAINT, "name, key, group only", 0, &scopeY);
    if (inputY < 0 || scopeY < 0) {
        printf("INCONCLUSIVE search box height: input y=%d scope y=%d\n",
               inputY, scopeY);
        return 0;
    }
    if (scopeY - inputY < AOWL_OV_LINE_H) {
        printf("error the search box is one line tall: its label and its "
               "scope line are %d pixels apart\n", scopeY - inputY);
        return 0;
    }
    printf("      search box, measured on the back buffer: label at y=%d, "
           "scope at y=%d, %d pixels apart\n", inputY, scopeY, scopeY - inputY);
    return 1;
}

/* Group headers are BANDS with a name and a count, and the rows they contain
 * sit below AND indented past them -- which is what makes a band read as a
 * container rather than as another row. */
static int check_group_bands(void) {
    int bandY = -1, rowY = -1;
    int bandX = panel_text_x(AOWL_OV_ACCENT, "Regeneration", 0, &bandY);
    int rowX = panel_text_x(AOWL_OV_TEXT, "Regen tick 0", 0, &rowY);
    if (bandX < 0 || rowX < 0) {
        printf("INCONCLUSIVE group bands: header x=%d, first row x=%d\n",
               bandX, rowX);
        return 0;
    }
    if (rowY <= bandY) {
        printf("error a group`s rows do not sit below its header band "
               "(band y=%d, row y=%d)\n", bandY, rowY);
        return 0;
    }
    {   /* Dump every TEXT run in a band of rows, with its measured x. */
        static OcrRun runs[512]; static char buf[65536]; int i2;
        g_ocrRuns = runs; g_ocrRunCap = 512; g_ocrRunN = 0;
        panel_read_text(buf, (int)sizeof(buf), AOWL_OV_TEXT);
        g_ocrRuns = NULL;
        for (i2 = 0; i2 < g_ocrRunN; i2++)
            if (runs[i2].y > 290 && runs[i2].y < 312) {
                char one[200]; const char* L = buf + runs[i2].at;
                const char* e2 = strchr(L, 10);
                size_t ln = e2 ? (size_t)(e2 - L) : strlen(L);
                if (ln > 190) ln = 190;
                memcpy(one, L, ln); one[ln] = 0;
                printf("      DEBUG TEXT run at (%d,%d): [%s]\n",
                       runs[i2].x, runs[i2].y, one);
            }
    }
    {   int q, yy;
        for (q = 0; q < 4; q++) {
            int xx = panel_text_x(AOWL_OV_TEXT, "Regen tick 0", q, &yy);
            if (xx < 0) break;
            printf("      DEBUG match %d of `Regen tick 0` at (%d,%d)\n", q, xx, yy);
        }
        for (q = 0; q < 4; q++) {
            int xx = panel_text_x(AOWL_OV_ACCENT, "Regeneration", q, &yy);
            if (xx < 0) break;
            printf("      DEBUG match %d of accent `Regeneration` at (%d,%d)\n", q, xx, yy);
        }
    }
    {   /* Say where the pane starts, so a surprising x is diagnosable rather
         * than just wrong. */
        float prx = 0.0f, prw = 0.0f;
        aowl_ov_panel_rect(&prx, NULL, &prw, NULL);
        printf("      (panel x=%d w=%d, scale=%d)\n", (int)prx, (int)prw,
               aowl_ov_scale());
    }
    if (rowX <= bandX) {
        printf("error a group`s rows are not indented past its header "
               "(band x=%d, row x=%d) -- the band does not read as a "
               "container\n", bandX, rowX);
        return 0;
    }
    printf("      group band, measured on the back buffer: header at (%d,%d), "
           "its first row at (%d,%d)\n", bandX, bandY, rowX, rowY);
    return 1;
}

/* Search: a term that matches a known setting must not return zero rows, and
 * a term that matches nothing must say so rather than showing everything. */
static int check_search(void) {
    static char faint[65536];
    int hits;
    if (g_ov.sItemCount <= 0) {
        printf("INCONCLUSIVE search: no page loaded\n");
        return 0;
    }
    hits = g_ov.filtCount;
    if (hits <= 0) {
        printf("error a term matching a known setting returned zero rows "
               "(term `%s`, %d rows on the page)\n", g_ov.search,
               g_ov.sItemCount);
        return 0;
    }
    /* Every result must carry WHERE it is, and it must still end in the
     * segment that DISTINGUISHES the hit.
     *
     * Clipped on the right the path read `Player/Health/Regenera..` --
     * present, plausible, and missing the only part that answers "which of the\n     * nine rows called Enabled is this one". So the check is on the TAIL, not
     * on the presence of a path. It fails on the right-clipped code this
     * replaced, which is its mutation proof. */
    panel_read_text_capped(faint, (int)sizeof(faint), AOWL_OV_FAINT,
                           "search results");
    if (!strstr(faint, "Regeneration")) {
        printf("error a search result`s group path does not carry its own "
               "deepest segment\n");
        return 0;
    }
    /* THE NEGATIVE, and it is the one that matters: no rendered path may end
     * in the right-clip marker. `Player > Health > Regenera..` satisfies the
     * check above and IS the failure -- present, plausible, and cut at the end
     * that identifies the hit. Truncation is allowed, but only from the LEFT,
     * where what it costs is the prefix every sibling shares. */
    if (strstr(faint, "Regenera..") || strstr(faint, "Player > Health >")) {
        printf("error a search result`s path is clipped on the RIGHT (or is "
               "untruncated and overflowing) -- the identifying end is what "
               "was lost\n");
        return 0;
    }
    /* ...and the box echoes the term AS TYPED. `aowl_ov_vk_char` hands back
     * virtual keys, so a letter arrives as its capital; a search field that
     * shouts REGEN back at somebody who typed regen reads as broken. */
    {
        static char text[65536];
        panel_read_text_capped(text, (int)sizeof(text), AOWL_OV_TEXT,
                               "search term");
        if (strstr(text, "REGEN")) {
            printf("error the search box upper-cased what was typed\n");
            return 0;
        }
        if (!strstr(text, "regener")) {
            printf("INCONCLUSIVE search echo: neither `regener` nor `REGENER` "
                   "is on screen, so nothing was read back (the decoder "
                   "ignores runs shorter than %d glyphs)\n", OCR_MIN_RUN);
            return 0;
        }
    }
    return 1;
}

/* MUTATION PROOF. Each check above is re-run against a table deliberately
 * broken in the one way it claims to detect, and it must FAIL. A check that
 * cannot fail is the bug -- so this is the only place in this file that
 * treats a `bad()` as the expected outcome. */
static int check_mutations(void) {
    char why[192];
    int okAll = 1;
    char savedLabel[64];
    int savedParent, savedHi;
    if (g_ov.catCount < 3) {
        printf("INCONCLUSIVE mutation proof: only %d nav nodes\n",
               g_ov.catCount);
        return 0;
    }
    /* 1. a group with no title */
    memcpy(savedLabel, g_ov.cats[1].label, sizeof(savedLabel));
    g_ov.cats[1].label[0] = 0;
    if (aowl_ov_cats_wellformed(why, (int)sizeof(why))) {
        printf("error MUTATION NOT CAUGHT: a nav node with an empty title "
               "passed cats_wellformed\n");
        okAll = 0;
    }
    memcpy(g_ov.cats[1].label, savedLabel, sizeof(savedLabel));

    /* 2. a node whose parent is wrong -- unreachable by breadcrumb */
    {
        int i, at = -1;
        for (i = 0; i < g_ov.catCount; i++)
            if (g_ov.cats[i].depth > 1) { at = i; break; }
        if (at < 0) {
            printf("INCONCLUSIVE mutation proof: the fixture has no nested "
                   "node to break\n");
            return 0;
        }
        savedParent = g_ov.cats[at].parent;
        g_ov.cats[at].parent = -1;
        if (aowl_ov_cats_wellformed(why, (int)sizeof(why))) {
            printf("error MUTATION NOT CAUGHT: a nav node with no parent "
                   "passed cats_wellformed\n");
            okAll = 0;
        }
        g_ov.cats[at].parent = savedParent;
    }

    /* 3. rows under no top-level group */
    savedHi = g_ov.cats[0].hi;
    g_ov.cats[0].hi = g_ov.cats[0].lo + 1;
    if (aowl_ov_cats_wellformed(why, (int)sizeof(why))) {
        printf("error MUTATION NOT CAUGHT: rows under no group passed "
               "cats_wellformed\n");
        okAll = 0;
    }
    g_ov.cats[0].hi = savedHi;

    /* 4. and the table must be intact again -- a mutation proof that leaves
     *    the fixture broken poisons every check after it. */
    if (!aowl_ov_cats_wellformed(why, (int)sizeof(why))) {
        printf("error the mutation proof did not restore the table: %s\n", why);
        okAll = 0;
    }
    return okAll;
}

/* SEND A KEY THE WAY WINDOWS SENDS IT.
 *
 * THE FIFTH INSTRUMENT LIE IN THIS FILE, and the most expensive so far: it let
 * a dead key pass its own test for a whole round.
 *
 * F10 is Windows' menu-activation key. The system delivers it as
 * WM_SYSKEYDOWN, never as WM_KEYDOWN, and the same is true of any key pressed
 * with Alt held. This harness was synthesising `SendMessageW(hwnd,
 * WM_KEYDOWN, VK_F10, 0)` -- a message the real world never produces for that
 * key -- so it walked straight into the panel's WM_KEYDOWN branch, moved
 * `panAlpha`, and the check said F10 worked. On the live client F10 arrived as
 * WM_SYSKEYDOWN, hit `default:`, and went to the game. The user reported it as
 * "works only in one direction F9".
 *
 * A test that sends a message the OS would not send is not testing the key; it
 * is testing the branch it already decided to aim at. Every keypress in this
 * file now goes through here, so the routing is decided in ONE place by the
 * same rule Windows uses.
 *
 * `extended` is the context-code bit (lParam 29): Alt-down. Bare F10 is a
 * system key WITHOUT it, which is exactly the case the panel has to take. */
static void send_key(HWND h, int vk) {
    if (vk == VK_F10)                       /* bare F10: syskey, Alt NOT down */
        SendMessageW(h, WM_SYSKEYDOWN, (WPARAM)vk, 0);
    else
        SendMessageW(h, WM_KEYDOWN, (WPARAM)vk, 0);
}

/* ADVANCE `n` FRAMES WITH THE SCENE HELD STILL.
 *
 * The main loop clears to `0.10 + 0.05*sin(f*0.03)` -- the scene behind the
 * panel MOVES EVERY FRAME, on purpose, so the overlay is composited over
 * something that changes. That is right for the rest of the run and fatal to a
 * pixel round trip: the panel background is blended over the scene, so the same
 * alpha two hundred frames apart renders to a different colour and "did it come
 * back to where it started" is unanswerable.
 *
 * So this pump clears to a CONSTANT. Holding the test's own input still is the
 * only way the measurement isolates the one variable it is about, and it is a
 * control on the fixture, not on the panel: nothing here touches the overlay.
 *
 * Returns 1 always, so it can be passed as the `pump` callback.
 */
static int pump_frames(int n) {
    int i;
    for (i = 0; i < n; i++) {
        MSG m;
        FLOAT fixed[4] = { 0.10f, 0.12f, 0.18f, 1.0f };
        while (PeekMessageW(&m, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, fixed);
        ID3D11DeviceContext_Draw(ctx, 3, 0);
        IDXGISwapChain_Present(swap, 0, 0);
    }
    return 1;
}

/* THE PANEL'S RENDERED BACKGROUND, as a number, read off the back buffer.
 *
 * The mean of R+G+B over the panel's interior. Not `panAlpha` -- that is the
 * stored value, and this surface has taught us repeatedly that a stored value
 * and a rendered result are different claims (the row relabel that re-read its
 * own write; the disassembly proof about a field that never reached the
 * screen). The panel background is blended over the scene, so a change in
 * alpha changes every interior pixel and the mean moves monotonically with it.
 *
 * Averaging over the whole interior rather than sampling one pixel: text and
 * chrome sit at fixed positions and are a minority of the area, and -- what
 * actually matters for the round trip -- the SAME alpha always produces the
 * SAME image and therefore exactly the same mean. Equality is preserved
 * whatever the text is doing.
 *
 * Returns -1 if the buffer could not be read, which callers turn into
 * INCONCLUSIVE and never into a pass. */
static int panel_bg_mean(void) {
    ID3D11Texture2D* bb = NULL;
    D3D11_TEXTURE2D_DESC td, sd;
    ID3D11Texture2D* stage = NULL;
    D3D11_MAPPED_SUBRESOURCE map;
    float px = 0.0f, py = 0.0f, pw = 0.0f, ph = 0.0f;
    double sum = 0.0;
    int n = 0, x, y, x0, y0, x1, y1, k;
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D,
                                        (void**)&bb)))
        return -1;
    ID3D11Texture2D_GetDesc(bb, &td);
    sd = td;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.BindFlags = 0;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sd.MiscFlags = 0;
    if (FAILED(ID3D11Device_CreateTexture2D(dev, &sd, NULL, &stage))) {
        ID3D11Texture2D_Release(bb);
        return -1;
    }
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)stage,
                                     (ID3D11Resource*)bb);
    if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)stage, 0,
                                       D3D11_MAP_READ, 0, &map))) {
        ID3D11Texture2D_Release(stage);
        ID3D11Texture2D_Release(bb);
        return -1;
    }
    /* ASK the panel where it is; never re-derive it. `aowl_ov_panel_rect`
     * exists precisely because this file used to compute the rect itself and
     * drifted 40px when the resize grip was added. Panel units times `scale`
     * gives back-buffer pixels. */
    aowl_ov_panel_rect(&px, &py, &pw, &ph);
    k = g_ov.scale > 0 ? g_ov.scale : 1;
    x0 = (int)(px * k) + 6;  y0 = (int)(py * k) + 6;
    x1 = (int)((px + pw) * k) - 6;  y1 = (int)((py + ph) * k) - 6;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int)td.Width)  x1 = (int)td.Width;
    if (y1 > (int)td.Height) y1 = (int)td.Height;
    for (y = y0; y < y1; y++) {
        const uint8_t* row = (const uint8_t*)map.pData + (size_t)y * map.RowPitch;
        for (x = x0; x < x1; x++) {
            const uint8_t* q = row + (size_t)x * 4;
            sum += (double)q[0] + (double)q[1] + (double)q[2];
            n++;
        }
    }
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)stage, 0);
    ID3D11Texture2D_Release(stage);
    ID3D11Texture2D_Release(bb);
    if (n < 100) return -1;
    /* Scaled by 1000 so a change of well under one 8-bit level is still a
     * different integer -- 27/255 of the blend spread over the interior is a
     * fraction of a level per pixel and would round to nothing otherwise. */
    return (int)(sum / (double)n * 1000.0);
}

/* ASK THE FIXTURE, over the wire, on this thread.
 *
 * The whole point of these checks is that the observer is not the thing being
 * observed: "how many writes arrived" has to be answered by the process that
 * received them. Blocking here is fine -- this is a scripted test frame, not a
 * game frame -- and it uses the overlay's own transport so there is no second
 * HTTP client to keep in step. Returns NULL when it could not ask, which the
 * callers turn into INCONCLUSIVE rather than into a pass. */
static char g_ask[65536];
static const char* ask_fixture(const wchar_t* path) {
    g_ask[0] = 0;
    if (aowl_ov_http(L"GET", path, NULL, g_ask, (int)sizeof(g_ask)) <= 0)
        return NULL;
    return g_ask;
}

/* How many settings writes the fixture has received for the deep page. Counted
 * from its `/posts` record by looking for the route, so it counts REQUESTS THAT
 * ARRIVED rather than anything this process intended to send. */
static int posts_seen(void) {
    const char* b = ask_fixture(L"/posts");
    const char* p;
    int n = 0;
    if (!b) return -1;
    for (p = b; (p = strstr(p, "/aowlspt/settings/aowl.deep")) != NULL; p++)
        n++;
    return n;
}

/* ==================================================================
 * THE FOUR NEW NEGATIVES
 *
 * Each is phrased so that an input exists which makes it fail, and each is
 * mutation-proved below in `check_new_mutations`. Three outcomes throughout:
 * PASS, FAIL, and INCONCLUSIVE for "I could not look" -- which is never a pass.
 * ================================================================== */

/* 1. NO NAV ROW RENDERS AT THE SAME X-OFFSET AS ITS OWN PARENT.
 *
 * The reported defect exactly: "Singleplayer" (the page) and the group inside
 * it had the same indentation, so nothing said one contained the other. Read
 * off the BACK BUFFER, and the page row is found in the page's own colour --
 * asking `g_ov` where it drew the label would be asking the code under test.
 *
 * The strong form is the parent comparison, not "depth1 is indented": a tree
 * whose every level shared one indent would pass "is indented" trivially. */
static int check_nav_depth1_indent(void) {
    int xPage, xD1;
    if (g_ov.sCatCount < 1) {
        printf("INCONCLUSIVE nav depth-1 indent: the page has no groups\n");
        return 0;
    }
    /* WHICH TWO WORDS, and why these two -- three instrument facts went into
     * it, each measured, none of them a property of the panel:
     *
     *  1. The glyph decoder IGNORES ANY RUN SHORTER THAN 6 (OCR_MIN_RUN), so it
     *     does not read noise as text. `nav_text_x(TEXT, "Bots")` -- the
     *     obvious needle for a depth-1 group -- returns -1 for a label plainly
     *     on screen, and that reads as "the nav did not draw it".
     *  2. A SPACE BREAKS A RUN, so the x of a needle is the x of ITS WORD, not
     *     of the label it sits in. "fixture" (the last word of the page label)
     *     measured 122 against a depth-1 group at 74, which reads as the page
     *     being indented further than its own child -- the exact opposite of
     *     the truth.
     *  3. On the SELECTED page row the first word does not decode at all, while
     *     the second on the same row does: probing "Deeper"/"Deeptree" both
     *     returned -1 while "Fixture" on that row returned 122 and "Fallback"
     *     -- the first word of the UNSELECTED page row -- returned 66. The
     *     selected page row carries a "- " disclosure marker where the
     *     unselected one carries "  ", so the leading glyph appears to be
     *     merging into the first word and corrupting it. NOT CHARACTERISED
     *     FURTHER, and this check does not depend on it.
     *
     *  4. AND `panel_text_x` REPORTS THE START OF THE RUN THE NEEDLE IS IN,
     *     NOT THE NEEDLE'S OWN x. This is the fourth instrument lie found in
     *     this file and it is the same one a previous round believed fixed.
     *
     *     Measured, and it is not subtle: "Player" and "Numbers" are BOTH
     *     depth-1 groups on the same page and must be drawn at the same x. They
     *     report 74 and 90. The difference is exactly 2 characters, and the
     *     cause is the disclosure marker -- "Player" has children so its label
     *     is drawn as "- Player" and the decoded run begins at the dash, while
     *     "Numbers" has none so its run is drawn as two SPACES (blank pixels,
     *     which start no run) followed by "Numbers". Same indent, two answers,
     *     16 px apart.
     *
     *     Working back through it the real ladder is a clean 24 px per level --
     *     page 50, depth-1 74, depth-2 98, depth-3 122, and 24 is exactly the
     *     `3 * AOWL_OV_CW` the nav intends. But no comparison here may mix a
     *     marker-bearing run with a marker-less one, or it is off by 16.
     *
     *     So BOTH needles below are chosen to be MARKER-LESS runs: "Fallback"
     *     is an unselected page row (drawn "  Fallback...") and "Numbers" is a
     *     depth-1 group with no children (drawn "  Numbers"). Both report
     *     `lx + 2 * CW`, the constant cancels, and the difference is the true
     *     indent. Reported to the caller as an instrument defect, not worked
     *     around silently. */
    xPage = nav_text_x(AOWL_OV_TEXT, "Fallback");
    xD1   = nav_text_x(AOWL_OV_TEXT, "Numbers");
    if (xPage < 0 || xD1 < 0) {
        static char dbg[65536];
        int n = panel_read_text(dbg, (int)sizeof(dbg), AOWL_OV_TEXT);
        printf("INCONCLUSIVE nav depth-1 indent: page x=%d, depth-1 x=%d "
               "(one of them did not decode)\n", xPage, xD1);
        /* Print what the decoder DID see. An INCONCLUSIVE with no evidence is
         * indistinguishable from a broken decoder, and this file has been
         * burned by exactly that: a needle under the 6-glyph minimum reads as
         * "the panel did not draw it". */
        printf("      decoder saw (%d bytes, TEXT): %.400s\n", n, dbg);
        {
            static const char* try_[] = { "Deeper", "Fixture", "Deeptree",
                                          "Fallback", "Player", "Numbers" };
            size_t ti;
            for (ti = 0; ti < sizeof(try_) / sizeof(try_[0]); ti++)
                printf("      probe '%s': nav x=%d, whole-panel x=%d\n",
                       try_[ti], nav_text_x(AOWL_OV_TEXT, try_[ti]),
                       panel_text_x(AOWL_OV_TEXT, try_[ti], 0, NULL));
        }
        return 0;
    }
    if (xD1 <= xPage) {
        printf("error a depth-1 group renders at or left of its own page: "
               "page x=%d, depth-1 group 'Player' x=%d -- the first level of "
               "nesting has no tree treatment\n", xPage, xD1);
        return 0;
    }
    printf("      nav depth-1, measured on the back buffer: page x=%d, its "
           "depth-1 group x=%d (+%d)\n", xPage, xD1, xD1 - xPage);
    /* The WHOLE LADDER, printed every run. A single "+N" says the first level
     * is indented and says nothing about whether it is indented as much as
     * every other level -- which is the difference between a tree and a tree
     * with one apologetic step in it. These are read, not asserted, so a
     * regression shows up as a number changing in the log. */
    printf("      nav ladder (RUN starts -- a row with a disclosure marker "
           "reads 16 low; see above): page=%d d1=%d d1+mark=%d d2+mark=%d "
           "d3=%d\n",
           xPage, xD1, nav_text_x(AOWL_OV_TEXT, "Player"),
           nav_text_x(AOWL_OV_DIM, "Health"),
           nav_text_x(AOWL_OV_FAINT, "Regeneration"));
    return 1;
}

/* 2. NO RENDERED ROW HAS `implemented:false`, AND NO GROUP IS LEFT EMPTY.
 *
 * Two halves, both negatives. The first is checked against the SCREEN -- the
 * fixture's hidden rows are labelled "Cultist circle N", a string that appears
 * nowhere else -- because the question is what the player sees. The second is
 * checked against the built nav, since an empty group is a structural thing
 * that has no pixels by definition; a group that exists with zero rows would
 * still print a band and a count of 0. */
static int check_unimpl_hidden(void) {
    static char text[65536];
    int i, okAll = 1;
    if (g_ov.showUnimpl) {
        printf("INCONCLUSIVE unimplemented filter: F8 is ON, so the rows are "
               "meant to be on screen\n");
        return 0;
    }
    if (g_ov.sItemCount <= 0) {
        printf("INCONCLUSIVE unimplemented filter: no rows loaded\n");
        return 0;
    }
    panel_read_text(text, (int)sizeof(text), AOWL_OV_TEXT);
    if (strstr(text, "Cultist")) {
        printf("error a row the schema marks implemented:false is on screen "
               "(found 'Cultist' in the panel text)\n");
        okAll = 0;
    }
    panel_read_text(text, (int)sizeof(text), AOWL_OV_DIM);
    if (strstr(text, "Cultist")) {
        printf("error a row marked implemented:false is on screen, dimmed -- "
               "dimming it is what this change replaces, not what it does\n");
        okAll = 0;
    }
    /* No row that survived the filter may be unimplemented. This is the
     * property, stated over the data the draw walks. */
    for (i = 0; i < g_ov.sItemCount; i++)
        if (!g_ov.sItems[i].implemented) {
            printf("error row %d (%s) is implemented:false and was kept\n",
                   i, g_ov.sItems[i].key);
            okAll = 0;
            break;
        }
    /* No group may exist with no rows in it. */
    for (i = 0; i < g_ov.sCatCount; i++)
        if (g_ov.sCats[i].hi <= g_ov.sCats[i].lo) {
            printf("error nav group '%s' survived with no rows in it\n",
                   g_ov.sCats[i].full);
            okAll = 0;
            break;
        }
    /* And the count the band prints must be the count of rows it heads --
     * `itemsImpl` counts only implemented rows, and with the filter on that is
     * every row there is. A mismatch means a count on screen that no row
     * supports, which is the "right-aligned counts include hidden rows" case. */
    if (g_ov.sItemsImpl != g_ov.sItemCount) {
        printf("error the implemented count (%d) and the row count (%d) "
               "disagree with the filter on\n",
               g_ov.sItemsImpl, g_ov.sItemCount);
        okAll = 0;
    }
    if (okAll)
        printf("      %d rows kept, %d hidden as not-implemented, %d groups, "
               "none empty\n", g_ov.sItemCount, g_ov.sHiddenCount,
               g_ov.sCatCount);
    return okAll;
}

/* A page every row of which is unimplemented must not be in the nav -- and must
 * NOT HAVE BEEN FETCHED to establish that. The second half is the one that
 * matters for cost: hiding 28 SPT pages by loading 28 SPT pages is not hiding
 * them, it is hiding them expensively. Answered by the fixture's own fetch
 * counter, over the wire, not by anything this process believes. */
static int check_dead_page_hidden(const char* fetchesJson) {
    int i, found = 0;
    for (i = 0; i < g_ov.sPageCount; i++)
        if (strcmp(g_ov.sPages[i].id, "aowl.dead") == 0) found = 1;
    if (found) {
        printf("error a page whose index says done:0 is still in the nav\n");
        return 0;
    }
    if (!fetchesJson) {
        printf("INCONCLUSIVE dead page: could not read the fixture's fetch "
               "counter, so 'never fetched' is unproven\n");
        return 0;
    }
    if (strstr(fetchesJson, "aowl.dead")) {
        printf("error the hidden page WAS fetched -- the nav is hiding it "
               "after paying for it: %s\n", fetchesJson);
        return 0;
    }
    printf("      the all-unimplemented page is absent from the nav and was "
           "never fetched (fixture says %s)\n", fetchesJson);
    return 1;
}

/* 3. EXACTLY ONE NUMERIC ROW MAY DRAW A SLIDER.
 *
 * The fixture declares six numbers: one with a well-formed range and five with
 * range shapes that must fall back (none, max only, min only, inverted, and a
 * span too wide for a 104px track to address). `hasRange` is the parser's
 * decision and is a pure function of the body, so it is the right thing to
 * assert -- and the check is a COUNT over all six rather than a look at the
 * good one, so a panel that sliders everything fails. */
static int check_slider_ranges(void) {
    int i, sliders = 0, numbers = 0, okAll = 1;
    for (i = 0; i < g_ov.sItemCount; i++) {
        AowlOvSItem* s = &g_ov.sItems[i];
        if (strcmp(s->path, "Numbers") != 0) continue;
        numbers++;
        if (s->hasRange) {
            sliders++;
            if (strcmp(s->key, "sliderok") != 0) {
                printf("error '%s' got a slider from a range that cannot "
                       "support one (lo=%g hi=%g step=%g)\n",
                       s->key, (double)s->lo, (double)s->hi, (double)s->step);
                okAll = 0;
            }
        }
        /* A step of zero would divide by zero in the drag; it must never
         * survive the parser whatever the body said. */
        if (s->step <= 0.0f) {
            printf("error '%s' kept a non-positive step (%g)\n",
                   s->key, (double)s->step);
            okAll = 0;
        }
    }
    if (numbers < 6) {
        printf("INCONCLUSIVE slider ranges: only %d numeric rows loaded\n",
               numbers);
        return 0;
    }
    if (sliders != 1) {
        printf("error %d of %d numeric rows drew a slider; exactly 1 has a "
               "range that can support one\n", sliders, numbers);
        okAll = 0;
    }
    if (okAll)
        printf("      %d numeric rows, 1 slider, %d steppers -- a missing or "
               "unusable range falls back rather than inventing bounds\n",
               numbers, numbers - 1);
    return okAll;
}

/* 4. A DRAG OF N FRAMES EMITS FEWER THAN N WRITES.
 *
 * Counted at the BACKEND, from its own record of what arrived, not from
 * `writeCount` -- which is the panel counting its own writes and is the
 * self-comparison CLAUDE.md 9b forbids. `writeCount` is printed alongside so
 * that a disagreement between the two is visible rather than silent. */
static int check_drag_coalesced(int frames, int postsBefore, int postsAfter,
                                int writesBefore, int writesAfter) {
    int sent = postsAfter - postsBefore;
    int claimed = writesAfter - writesBefore;
    if (postsBefore < 0 || postsAfter < 0) {
        printf("INCONCLUSIVE drag coalescing: the backend's POST record could "
               "not be read\n");
        return 0;
    }
    if (sent < 1) {
        printf("error a %d-frame drag sent NO write at all -- coalescing that "
               "coalesces to zero is a dropped edit, not a saving\n", frames);
        return 0;
    }
    if (sent >= frames) {
        printf("error a %d-frame drag sent %d writes; each one POSTs AND "
               "re-GETs the whole page\n", frames, sent);
        return 0;
    }
    if (sent != claimed)
        printf("      NOTE: the panel counted %d writes and the backend "
               "received %d\n", claimed, sent);
    printf("      a %d-frame slider drag produced %d write%s at the backend\n",
           frames, sent, sent == 1 ? "" : "s");
    return 1;
}

/* A TYPED VALUE IS READ BACK OVER THE WIRE UNCHANGED.
 *
 * The fixture stores what it is POSTed and serves it from the next GET, so this
 * reads the value the ROUND TRIP produced. Checked on the SCREEN, because a
 * value that reached the file and does not reach the row is the defect this
 * project has shipped before (`SetGameModeText` wrote the right field on the
 * wrong object). Fact #135 is why status codes are not consulted anywhere here.
 */
static int check_typed_readback(const char* wantText) {
    static char text[65536];
    int i, at = -1;
    for (i = 0; i < g_ov.sItemCount; i++)
        if (strcmp(g_ov.sItems[i].key, "sliderok") == 0) at = i;
    if (at < 0) {
        printf("INCONCLUSIVE typed value: the row is not loaded\n");
        return 0;
    }
    if (strcmp(g_ov.sItems[at].value, wantText) != 0) {
        printf("error a typed value did not survive the round trip: the row "
               "reads '%s', the wire was told '%s'\n",
               g_ov.sItems[at].value, wantText);
        return 0;
    }
    panel_read_text(text, (int)sizeof(text), AOWL_OV_TEXT);
    if (!strstr(text, wantText)) {
        printf("error the typed value '%s' is in the table but is not on "
               "screen\n", wantText);
        return 0;
    }
    printf("      a typed value round-tripped: POSTed, re-GET, and rendered "
           "as '%s'\n", wantText);
    return 1;
}

/* 5. F9 AND F10 ARE A SYMMETRIC PAIR, PROVED ON THE PIXELS.
 *
 * Three separate claims, because "F10 does not work" has three different
 * causes and this instrument can tell them apart:
 *
 *   a. THE KEY FIRES AT ALL. `panAlpha` moves when F10 is pressed. If this
 *      fails the key never reached the handler -- which is what was actually
 *      wrong: F10 arrives as WM_SYSKEYDOWN and the panel only took WM_KEYDOWN.
 *   b. THE VALUE MOVES THE OTHER WAY. F9 and F10 must move `panAlpha` in
 *      OPPOSITE directions. Catches a wrong sign and a shared step variable.
 *   c. THE RENDER FOLLOWS, AND ROUND-TRIPS. N presses of F9 then N of F10 must
 *      return the RENDERED background to where it started. This is the one the
 *      coordinator asked for and it is the strongest: it fails if either
 *      direction is dead, if the steps are unequal, if one saturates against a
 *      bound the other does not, or if the value moves and the draw ignores it.
 *
 * Plus: BOTH BOUNDS MUST BE REACHABLE and must differ. "Works in one
 * direction" can also mean "already sitting on the bound it steps toward", and
 * a round trip taken entirely at a clamp passes trivially -- start-at-a-bound
 * is exactly the input that would make (c) pass while the pair is broken, so
 * it is run from mid-range and the bounds are checked separately.
 *
 * Every reading is `panel_bg_mean` off the back buffer, never `panAlpha`. */
static int check_opacity_pair(HWND h, int (*pump)(int)) {
    int i, midAlpha, aAfterF9, aAfterF10;
    int bg0, bg1, bg2, darkest, lightest, darkA, lightA;
    const int kN = 4;

    /* --- both bounds, first, so the round trip below is known to start away
     *     from either of them. 20 presses is more than (255-40)/27. */
    for (i = 0; i < 20; i++) { send_key(h, VK_F9);  pump(1); }
    darkA = g_ov.panAlpha;  darkest  = panel_bg_mean();
    for (i = 0; i < 20; i++) { send_key(h, VK_F10); pump(1); }
    lightA = g_ov.panAlpha; lightest = panel_bg_mean();
    if (darkest < 0 || lightest < 0) {
        printf("INCONCLUSIVE opacity: the back buffer could not be read\n");
        return 0;
    }
    if (darkA == lightA) {
        printf("error F9 and F10 saturate at the SAME alpha (%d) -- the pair "
               "has one direction\n", darkA);
        return 0;
    }
    if (darkest == lightest) {
        printf("error the two opacity bounds (alpha %d and %d) RENDER "
               "identically (%d) -- the value moves and the draw does not\n",
               darkA, lightA, darkest);
        return 0;
    }

    /* --- mid-range: 3 presses of F9 off the solid bound we are now sitting on. */
    for (i = 0; i < 3; i++) { send_key(h, VK_F9); pump(1); }
    midAlpha = g_ov.panAlpha;
    if (midAlpha == darkA || midAlpha == lightA) {
        printf("INCONCLUSIVE opacity round trip: could not leave a bound "
               "(alpha %d, bounds %d/%d)\n", midAlpha, darkA, lightA);
        return 0;
    }
    bg0 = panel_bg_mean();

    for (i = 0; i < kN; i++) { send_key(h, VK_F9); pump(1); }
    aAfterF9 = g_ov.panAlpha;
    bg1 = panel_bg_mean();
    for (i = 0; i < kN; i++) { send_key(h, VK_F10); pump(1); }
    aAfterF10 = g_ov.panAlpha;
    bg2 = panel_bg_mean();
    if (bg0 < 0 || bg1 < 0 || bg2 < 0) {
        printf("INCONCLUSIVE opacity round trip: a frame did not read back\n");
        return 0;
    }
    /* (a) and (b): the two keys must move the stored value in opposite ways. */
    if (aAfterF9 >= midAlpha) {
        printf("error %d presses of F9 did not lower the alpha (%d -> %d)\n",
               kN, midAlpha, aAfterF9);
        return 0;
    }
    if (aAfterF10 <= aAfterF9) {
        printf("error %d presses of F10 did not raise the alpha (%d -> %d) -- "
               "F10 is dead or moves the same way as F9\n",
               kN, aAfterF9, aAfterF10);
        return 0;
    }
    /* (c) the round trip, on the stored value AND on the pixels. */
    if (aAfterF10 != midAlpha) {
        printf("error F9 x%d then F10 x%d did not return the alpha: %d -> %d "
               "-> %d; the two steps are not equal and opposite\n",
               kN, kN, midAlpha, aAfterF9, aAfterF10);
        return 0;
    }
    if (bg1 == bg0) {
        printf("error %d presses of F9 changed the alpha (%d -> %d) and the "
               "RENDERED background did not move (%d)\n",
               kN, midAlpha, aAfterF9, bg0);
        return 0;
    }
    /* "within rounding": the mean is scaled by 1000, so a whole 8-bit level is
     * 1000. A round trip to the identical alpha must reproduce the identical
     * image; anything above a hair of blend noise is a real difference. */
    if (bg2 < bg0 - 20 || bg2 > bg0 + 20) {
        printf("error the RENDERED background did not round-trip: %d -> %d -> "
               "%d (alpha %d -> %d -> %d)\n",
               bg0, bg1, bg2, midAlpha, aAfterF9, aAfterF10);
        return 0;
    }
    printf("      opacity pair: alpha %d -F9x%d-> %d -F10x%d-> %d; rendered "
           "background %d -> %d -> %d; bounds alpha %d..%d render %d..%d\n",
           midAlpha, kN, aAfterF9, kN, aAfterF10, bg0, bg1, bg2,
           darkA, lightA, darkest, lightest);
    return 1;
}

/* A pump that does not pump. Keys are queued by the wndproc and consumed by
 * the RENDER thread during the draw, so with no frames in between a keypress
 * never takes effect -- which is behaviourally identical, from the check's
 * point of view, to a key that never reached the panel at all. That is exactly
 * the bug that shipped (F10 arriving as WM_SYSKEYDOWN and being dropped), so
 * it is the right thing to prove the check catches. */
static int pump_none(int n) { (void)n; return 1; }

/* THE MUTATION PROOF for the opacity pair. Handed a world in which the keys do
 * not take effect, `check_opacity_pair` MUST fail. If it passes here it is a
 * check that cannot fail, and a check that cannot fail is the bug -- which is
 * precisely how the old `SendMessageW(WM_KEYDOWN, VK_F10)` test reported a
 * dead key as working for a whole round. */
static int check_opacity_mutation(HWND h, int (*realPump)(int)) {
    int okAll = 1;
    int saved = g_ov.panAlpha;
    if (check_opacity_pair(h, pump_none)) {
        printf("error MUTATION NOT CAUGHT: the opacity pair passed in a world "
               "where no keypress ever takes effect\n");
        okAll = 0;
    }
    /* RESTORE. The mutation left a pile of unconsumed keys in the ring, and a
     * fixture left broken poisons every check after it -- the same rule
     * `check_mutations` follows. Drain them, then put the alpha back. */
    realPump(64);
    while (g_ov.panAlpha > saved) { send_key(h, VK_F9);  realPump(1); }
    while (g_ov.panAlpha < saved) { send_key(h, VK_F10); realPump(1); }
    if (g_ov.panAlpha != saved) {
        printf("error the opacity mutation proof did not restore the alpha "
               "(%d, wanted %d)\n", g_ov.panAlpha, saved);
        okAll = 0;
    }
    return okAll;
}

/* THE MUTATION PROOF for the four above. Each check is handed the state it
 * claims to detect and must FAIL. A check that cannot fail is the bug. */
static int check_new_mutations(void) {
    int okAll = 1;
    int savedImpl, savedRange, savedCount;
    char savedVal[64];

    /* 1. an unimplemented row smuggled back into the kept set */
    if (g_ov.sItemCount < 1) {
        printf("INCONCLUSIVE new mutation proof: no rows\n");
        return 0;
    }
    savedImpl = g_ov.sItems[0].implemented;
    savedCount = g_ov.sItemsImpl;
    g_ov.sItems[0].implemented = 0;
    g_ov.sItemsImpl = g_ov.sItemCount;   /* keep the count half quiet */
    if (check_unimpl_hidden()) {
        printf("error MUTATION NOT CAUGHT: an implemented:false row in the "
               "kept set passed the hidden-rows check\n");
        okAll = 0;
    }
    g_ov.sItems[0].implemented = savedImpl;
    g_ov.sItemsImpl = savedCount;

    /* 2. a second slider, from a range that cannot support one */
    {
        int i, at = -1;
        for (i = 0; i < g_ov.sItemCount; i++)
            if (strcmp(g_ov.sItems[i].key, "norange") == 0) at = i;
        if (at < 0) {
            printf("INCONCLUSIVE new mutation proof: the no-range row is not "
                   "loaded\n");
            return 0;
        }
        savedRange = g_ov.sItems[at].hasRange;
        g_ov.sItems[at].hasRange = 1;
        g_ov.sItems[at].lo = 0.0f; g_ov.sItems[at].hi = 100.0f;
        if (check_slider_ranges()) {
            printf("error MUTATION NOT CAUGHT: a row with no declared range "
                   "drew a slider and passed the range check\n");
            okAll = 0;
        }
        g_ov.sItems[at].hasRange = savedRange;
    }

    /* 3. a drag that wrote every frame */
    if (check_drag_coalesced(60, 0, 60, 0, 60)) {
        printf("error MUTATION NOT CAUGHT: 60 writes from a 60-frame drag "
               "passed the coalescing check\n");
        okAll = 0;
    }
    /* ...and one that wrote nothing at all, which is the opposite failure and
     * the one a naive "fewer is better" check would call a pass. */
    if (check_drag_coalesced(60, 7, 7, 0, 0)) {
        printf("error MUTATION NOT CAUGHT: a drag that sent ZERO writes "
               "passed the coalescing check\n");
        okAll = 0;
    }

    /* 4. a typed value the round trip did not preserve */
    {
        int i, at = -1;
        for (i = 0; i < g_ov.sItemCount; i++)
            if (strcmp(g_ov.sItems[i].key, "sliderok") == 0) at = i;
        if (at >= 0) {
            memcpy(savedVal, g_ov.sItems[at].value, sizeof(savedVal));
            strcpy(g_ov.sItems[at].value, "999");
            if (check_typed_readback("543210")) {
                printf("error MUTATION NOT CAUGHT: a row reading 999 passed a "
                       "read-back check for 543210\n");
                okAll = 0;
            }
            memcpy(g_ov.sItems[at].value, savedVal, sizeof(savedVal));
        }
    }

    /* 5. the dead-page check must fail when the page IS in the nav. Mutated by
     *    naming a page that is there, which is the same question asked of a
     *    row that exists -- no table is left modified. */
    if (g_ov.sPageCount > 0) {
        char saved[80];
        memcpy(saved, g_ov.sPages[0].id, sizeof(saved));
        strcpy(g_ov.sPages[0].id, "aowl.dead");
        if (check_dead_page_hidden("{}")) {
            printf("error MUTATION NOT CAUGHT: a page in the nav passed the "
                   "hidden-page check\n");
            okAll = 0;
        }
        memcpy(g_ov.sPages[0].id, saved, sizeof(saved));
    }
    return okAll;
}

/* The launch hint. Falsifiable both ways: VISIBLE at one time and GONE at a
 * later one, both read back rather than asserted from the draw call. */
static int check_hint_up(void) {
    static char text[65536];
    panel_read_text(text, (int)sizeof(text), AOWL_OV_TEXT);
    if (!strstr(text, "Press F12 for Mod Settings")) {
        printf("error the launch hint is not on screen when it should be "
               "(state %d, drawn on %d frames)\n",
               aowl_ov_hint_state(), aowl_ov_hint_frames());
        return 0;
    }
    return 1;
}

static int check_hint_gone(void) {
    static char text[65536];
    panel_read_text(text, (int)sizeof(text), AOWL_OV_TEXT);
    if (strstr(text, "Press F12 for Mod Settings")) {
        printf("error the launch hint is STILL on screen after its hold and "
               "fade (state %d)\n", aowl_ov_hint_state());
        return 0;
    }
    if (aowl_ov_hint_frames() <= 0) {
        printf("INCONCLUSIVE launch hint: it was never drawn at all, so "
               "`gone` proves nothing (enabled=%d, state=%d)\n",
               g_ov.hintEnabled, aowl_ov_hint_state());
        return 0;
    }
    return 1;
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */

static LRESULT CALLBACK hostProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CLOSE) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

static int make_rtv(void) {
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(swap, 0, &AOWL_IID_ID3D11Texture2D, (void**)&bb)))
        return 0;
    HRESULT hr = ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource*)bb, NULL, &rtv);
    ID3D11Texture2D_Release(bb);
    return SUCCEEDED(hr);
}

int main(int argc, char** argv) {
    /* 300 rather than 240: the scripted run reaches frame 172, and everything
     * after that exists so the frame-cost average has a hundred steady-state
     * frames to settle over rather than reporting start-up. */
    int headless = 0, frames = 300;
    const char* shotDir = NULL;
    /* `--fill N` pushes N synthetic mods in, up to the table's own ceiling, and
     * `--size WxH` opens the window at a real resolution. Together they are the
     * case nobody had tried: a full 64-mod table on a 4K panel, which is where
     * the fixed vertex buffer would overflow if it were going to. */
    int fill = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--headless") == 0) headless = 1;
        else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) frames = atoi(argv[++i]);
        else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) {
            shotDir = argv[++i];
            /* Create it rather than write nothing. `shoot()` fails quietly
             * against a directory that is not there, so `--shot shots-4k` on a
             * clean checkout used to run the whole script, report every check
             * as passing, and produce not one BMP -- and the BMPs are the only
             * evidence the panel drew what it says it drew. */
            if (!CreateDirectoryA(shotDir, NULL) &&
                GetLastError() != ERROR_ALREADY_EXISTS) {
                printf("error --shot %s: cannot create that directory (%lu)\n",
                       shotDir, (unsigned long)GetLastError());
                return 1;
            }
        }
        else if (strcmp(argv[i], "--fill") == 0 && i + 1 < argc) fill = atoi(argv[++i]);
        else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            unsigned w = 0, h = 0;
            if (sscanf(argv[++i], "%ux%u", &w, &h) == 2 && w >= 320 && h >= 240) {
                winW = w; winH = h;
            }
        }
    }

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = hostProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"aowlspt_overlayhost";
    RegisterClassExW(&wc);
    hwnd = CreateWindowExW(0, L"aowlspt_overlayhost", L"aowlspt overlay test host",
                           WS_OVERLAPPEDWINDOW, 80, 80, (int)winW, (int)winH,
                           NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { bad("could not create the window"); return 1; }
    ShowWindow(hwnd, headless ? SW_HIDE : SW_SHOW);

    DXGI_SWAP_CHAIN_DESC scd;
    memset(&scd, 0, sizeof(scd));
    scd.BufferCount = 1;
    scd.BufferDesc.Width = winW;
    scd.BufferDesc.Height = winH;
    scd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.OutputWindow = hwnd;
    scd.SampleDesc.Count = 1;
    scd.Windowed = TRUE;
    /* SEQUENTIAL, not DISCARD: the back buffer must still hold what was
     * presented so `shoot()` can read it. */
    scd.SwapEffect = DXGI_SWAP_EFFECT_SEQUENTIAL;

    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL,
                    0, NULL, 0, D3D11_SDK_VERSION, &scd, &swap, &dev, &fl, &ctx);
    if (FAILED(hr))
        hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_WARP, NULL,
                    0, NULL, 0, D3D11_SDK_VERSION, &scd, &swap, &dev, &fl, &ctx);
    if (FAILED(hr)) { bad("could not create a D3D11 device"); return 1; }
    ok("D3D11 device and swap chain");

    /* Which adapter, printed. The frame cost this run reports is a number about
     * a particular GPU, and "50 microseconds" means something very different on
     * a discrete card and on the WARP software rasteriser the HARDWARE path
     * falls back to on a machine with no usable driver. A perf figure with no
     * device beside it is not a measurement. */
    {
        IDXGIDevice* dxdev = NULL;
        static const GUID iidDxgiDevice =
            { 0x54ec77fa, 0x1377, 0x44e6, { 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
        if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &iidDxgiDevice, (void**)&dxdev))) {
            IDXGIAdapter* ad = NULL;
            if (SUCCEEDED(IDXGIDevice_GetAdapter(dxdev, &ad))) {
                DXGI_ADAPTER_DESC ds;
                if (SUCCEEDED(IDXGIAdapter_GetDesc(ad, &ds)))
                    printf("      device: %ls (feature level %x.%x)\n",
                           ds.Description, (unsigned)(fl >> 12) & 0xF,
                           (unsigned)(fl >> 8) & 0xF);
                IDXGIAdapter_Release(ad);
            }
            IDXGIDevice_Release(dxdev);
        }
    }

    if (!make_rtv()) { bad("could not create the host's render target view"); return 1; }
    if (!scene_init()) { bad("could not build the stand-in scene"); return 1; }
    scene_bind();
    ok("stand-in scene ready (pipeline state set once, never re-set)");

    /* Port 0 disables the HTTP client; the CI run has no backend to talk to
     * and a poll thread waiting on a closed port would just add noise. Pass a
     * real port to exercise it. */
    int32_t port = 0;
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) port = atoi(argv[i + 1]);

    if (!aowl_ov_start(VK_INSERT, port)) {
        char why[256];
        aowl_ov_status(why, sizeof(why));
        printf("error overlay start failed: %s\n", why);
        return 1;
    }
    ok("Present and ResizeBuffers detoured from a probe swap chain's vtable");

    /* What this process claims about its own library table, which is what
     * `aowlhost.nim` pushes in through `aowl_ov_set_mod`. Kept as a table
     * rather than five bare calls because the checks at the bottom of this file
     * need to know which of these guids were pushed as *loaded*: a row that is
     * not running because the host said so is right, and a row that is not
     * running because the backend said so is only right where the client host
     * answered about it, and the panel row cannot tell you which happened.
     *
     * `aowl.fovfix` is here because it is in the real registry, and therefore
     * in `panel.golden.json` -- so the golden fixture, not just the
     * hand-written one, has a guid that is both pushed in by this process and
     * reported on by a client host. Without it the run against real bytes had
     * no row where the two sources meet, which is the exact case the rule
     * below exists for. */
    static const struct { const char* guid; const char* name; const char* ver;
                          int32_t live; } kPushed[] = {
        { "aowl.clientprobe", "clientprobe",          "0.1.0", 1 },
        { "aowl.sway",        "SWAY",                 "1.4.2", 1 },
        { "aowl.efmb",        "EscapeFromMyBasement", "0.3.0", 0 },
        { "aowl.loot",        "LootRebalance",        "2.0.1", 1 },
        { "aowl.fovfix",      "FOV Fix",              "4.1.0", 1 },
    };
    for (size_t k = 0; k < sizeof(kPushed) / sizeof(kPushed[0]); k++)
        aowl_ov_set_mod(kPushed[k].guid, kPushed[k].name, kPushed[k].ver,
                        kPushed[k].live);

    /* Loaded, and then taken out again -- which is exactly the pair of calls
     * `aowlhost.nim` makes when a mod is unloaded while the game runs, and the
     * one case no backend is involved in. The row must end up saying it is not
     * running: it used to say it was, forever, because the push pinned
     * `loaded` at 1 in both directions. */
    aowl_ov_set_mod("aowl.unloaded", "UnloadedMidSession", "1.0.0", 1);
    aowl_ov_set_mod("aowl.unloaded", "UnloadedMidSession", "1.0.0", 0);
    {
        int32_t at = -1;
        for (int32_t k = 0; k < g_ov.modCount; k++)
            if (strcmp(g_ov.mods[k].guid, "aowl.unloaded") == 0) at = k;
        if (at < 0)
            bad("the unloaded row is not in the table at all");
        else if (g_ov.mods[at].loaded)
            bad("a mod the host unloaded still reads as running on the panel");
        else
            ok("a mod the host loaded and then unloaded reads as not running");
    }

    /* The stress case. Names and guids are as long as the row's fields allow,
     * because a short name is a short row and the point is to find the ceiling:
     * every glyph drawn is six vertices out of a fixed 24,576. */
    for (int i = 0; i < fill; i++) {
        char guid[80], name[64], ver[24];
        _snprintf(guid, sizeof(guid),
                  "com.example.verylongreversedomain.filler%03d", i);
        _snprintf(name, sizeof(name), "Filler Mod With A Long Name %03d", i);
        _snprintf(ver, sizeof(ver), "%d.%d.%d", i / 100, (i / 10) % 10, i % 10);
        guid[sizeof(guid) - 1] = name[sizeof(name) - 1] = ver[sizeof(ver) - 1] = 0;
        aowl_ov_set_mod(guid, name, ver, i & 1);
    }
    if (fill > 0) {
        char m[96];
        _snprintf(m, sizeof(m), "pushed %d filler rows; the table holds %d",
                  fill, g_ov.modCount);
        ok(m);
    }

    int printMismatches = 0, drewPixels = 0, resizeOk = -1;
    char path[512];
    int32_t backendRows = 0;
    /* A high-water mark rather than an end-state reading: the last
     * gesture in the script is a `C` that can legitimately be refused
     * (clearing an override on a row that has none), and a refusal
     * correctly clears the outcome list. The question is whether per-mod
     * outcomes ever reached the panel, not whether they are still there. */
    int32_t sawResults = 0;
    int32_t protRow = -1, protWas = 0, protHeld = 0;
    char    protGuid[80] = {0};
    /* The mouse half of the same rule. Clicking where a protected row's button
     * would be must not toggle it -- there is no button there, only `KEEP` --
     * and clicking the row must still *select* it, because a row you cannot
     * select is a row whose `reason` and `from` you cannot read. The two used
     * to be the same refusal: the draw loop `continue`d past the row-select hit
     * test, so the protected row was the one row the mouse could not reach, and
     * with the shipped registry that is row zero. */
    int32_t protBtnMoved = -1, protRowSel = -1, protRowMoved = -1;
    int32_t protMouseX = 0, protMouseY = 0;
    /* the keyboard path */
    int32_t keyRow = 0, keyWas = 0, keySelOk = 0, keyToggled = 0;
    char    keyGuid[80] = {0};
    int32_t tabbedToLists = 0, tabbedRound = 0;
    int legendChecked = 0, legendOk = 0, costLabelOk = -1;
    /* The settings-screen and window acts. -1 is "not attempted", which is
     * INCONCLUSIVE and is reported separately from 0 (attempted and failed) --
     * a run with no backend must not read as a pass. */
    int groupTitlesOk = -1, crumbOk = -1, mutationOk = -1, searchOk = -1;
    int searchFocusOk = -1, emptyTermOk = -1, clearedOk = -1;
    int maxOk = -1, restoreOk = -1, alphaOk = -1;
    /* The look-and-feel pass. Every one of these is a measurement taken off
     * the back buffer, not a claim about a coordinate we computed. */
    int depthOk = -1, bandsOk = -1, bigBoxOk = -1, indentMutOk = -1;
    int selectedOk = -1, collapseOk = -1, collapsePre = -1;
    int unfocusedKeyOk = -1, focusedKeyOk = -1;
    int keyAlphaWas = 0, keyFocusWas = 0;
    /* --- the slider / filter / tree act. -1 is "never ran", which is reported
     * as INCONCLUSIVE at the bottom and never as a pass. */
    int navIndentOk = -1, unimplOk = -1, rangesOk = -1, deadPageOk = -1;
    int dragCoalOk = -1, typedOk = -1, typeBoxOpenOk = -1, numOnlyOk = -1;
    int f8FromFieldOk = -1, f8ShowsOk = -1, newMutOk = -1;
    int opacityOk = -1, opacityMutOk = -1;
    int postsBefore = -1, writesBefore = 0, dragRow = -1;
    int f8FromFieldWas = 0, f8FocusWas = 0;
    /* Long enough that "fewer than N" is a real claim: at one write a frame
     * this would be 90 POSTs, each of which re-GETs the whole page. */
    const int kDragFrames = 90;
    int hintUpOk = -1, hintGoneOk = -1;
    int alphaWas = 0;
    float movedFromX = 0.0f, movedFromW = 0.0f;
    int32_t filterWas = -1, filterMoved = 0;
    int32_t listRow = -1;
    char    listId[64] = {0};
    /* the mouse path */
    int32_t mouseX = 0, mouseY = 0, mouseWas = -1, mouseMoved = 0;
    char    mouseGuid[80] = {0};

    for (int f = 0; f < frames; f++) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) { f = frames; break; }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        float t = (float)f * 0.03f;
        FLOAT clear[4] = { 0.10f + 0.05f * (float)sin(t), 0.12f, 0.18f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_Draw(ctx, 3, 0);

        Print before, after;
        fingerprint(&before);
        IDXGISwapChain_Present(swap, headless ? 0 : 1, 0);
        fingerprint(&after);
        if (!print_eq(&before, &after)) printMismatches++;

        if (headless) {
            if (g_ov.resultCount > sawResults) sawResults = g_ov.resultCount;
            /* A scripted run of the whole manager, driven the way a player
             * drives it: through the window procedure the overlay installed,
             * with keys. Every step below is a `SendMessageW` that the game's
             * own wndproc would have received, so nothing here reaches around
             * the input path being tested.
             *
             * The mouse is exercised too, once, on the row button -- it is a
             * supported gesture and it is the one that regressed silently when
             * the panel got wider. */
            if (f == 20) SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            if (f == 30 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\01-mods.bmp", shotDir);
                if (shoot(path)) ok("wrote 01-mods.bmp");
            }
            if (f == 34) drewPixels = count_overlay_pixels();
            /* Before the first gesture: a refusal puts its sentence in the
             * legend's second line in place of the markers, and after that
             * there is no marker legend on screen to check. */
            if (f == 35 && !legendChecked) {
                legendChecked = 1;
                legendOk = check_legend();
            }

            /* --- pick a row with the keyboard and toggle it --------------
             *
             * With a backend up the row chosen is the first one the *backend*
             * contributed rather than a fixed index: everything checked after
             * the toggle -- the `*`, the grey-out, the POST -- is the manager's
             * answer about a mod, and the manager can only answer about mods in
             * its registry. The rows the test host pushes in are deliberately
             * named after mods it does not have. */
            if (f == 38) {
                keyRow = 0;
                for (int32_t k = 0; k < g_ov.modCount; k++) {
                    /* Not a protected mod. Toggling `aowl.manager` off is a
                     * real gesture with a real answer -- it unloads the mod
                     * serving every route this panel reads -- and the first
                     * version of this script did exactly that, then spent the
                     * rest of the run reporting an empty backend. Both the
                     * manager and the panel refuse it now; the test picks a row
                     * that is not protected, because a refusal is not a toggle.
                     *
                     * By the row's own flag rather than by name: which mods are
                     * protected is the manager's business, and a test that
                     * hardcodes a guid is the thing that just got deleted from
                     * the header. */
                    if (g_ov.mods[k].hostPushed) continue;
                    if (g_ov.mods[k].protectedRow) continue;
                    keyRow = k;
                    break;
                }
                strncpy(keyGuid, g_ov.mods[keyRow].guid, sizeof(keyGuid) - 1);
                keyWas = g_ov.mods[keyRow].enabled;
                SendMessageW(hwnd, WM_KEYDOWN, VK_HOME, 0);
                for (int32_t k = 0; k < keyRow; k++)
                    SendMessageW(hwnd, WM_KEYDOWN, VK_DOWN, 0);
            }
            if (f == 40) {
                /* The cursor has to have landed on the row the arrows walked
                 * to before SPACE is pressed, or the toggle is of something
                 * else and every check after it is meaningless. */
                keySelOk = (g_ov.sel[AOWL_VIEW_MODS] == keyRow);
                SendMessageW(hwnd, WM_KEYDOWN, VK_SPACE, 0);
            }
            if (f == 50) {
                /* Read the answer *here*, not at the end of the run: the list
                 * switch a hundred frames later re-resolves every row, and a
                 * mod that came back on because a list turned it on is not
                 * evidence that SPACE did nothing. */
                for (int32_t k = 0; k < g_ov.modCount; k++)
                    if (strcmp(g_ov.mods[k].guid, keyGuid) == 0)
                        keyToggled = (g_ov.mods[k].enabled != keyWas) ||
                                     g_ov.mods[k].pending;
            }
            if (f == 52 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\02-toggled.bmp", shotDir);
                if (shoot(path)) ok("wrote 02-toggled.bmp");
            }

            /* --- the other three views, by keyboard ---------------------- */
            if (f == 56) SendMessageW(hwnd, WM_KEYDOWN, VK_TAB, 0);
            if (f == 58) tabbedToLists = (g_ov.view == AOWL_VIEW_LISTS);
            if (f == 62 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\03-lists.bmp", shotDir);
                if (shoot(path)) ok("wrote 03-lists.bmp");
            }
            /* Pick the first list that is not already active and make it the
             * active one -- the "switch between named lists" gesture. */
            if (f == 64 && g_ov.listCount > 0) {
                for (int32_t k = 0; k < g_ov.listCount; k++)
                    if (!g_ov.lists[k].active) { listRow = k; break; }
                if (listRow >= 0) {
                    strncpy(listId, g_ov.lists[listRow].id, sizeof(listId) - 1);
                    SendMessageW(hwnd, WM_KEYDOWN, VK_HOME, 0);
                    for (int32_t k = 0; k < listRow; k++)
                        SendMessageW(hwnd, WM_KEYDOWN, VK_DOWN, 0);
                    SendMessageW(hwnd, WM_KEYDOWN, VK_RETURN, 0);
                }
            }
            if (f == 78 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\04-list-picked.bmp", shotDir);
                if (shoot(path)) ok("wrote 04-list-picked.bmp");
            }
            if (f == 82) SendMessageW(hwnd, WM_KEYDOWN, VK_TAB, 0);
            if (f == 86 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\05-issues.bmp", shotDir);
                if (shoot(path)) ok("wrote 05-issues.bmp");
            }
            if (f == 88) SendMessageW(hwnd, WM_KEYDOWN, VK_TAB, 0);
            if (f == 92 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\06-apply.bmp", shotDir);
                if (shoot(path)) ok("wrote 06-apply.bmp");
            }
            if (f == 94) tabbedRound = (g_ov.view == AOWL_VIEW_APPLY);
            if (f == 96) SendMessageW(hwnd, WM_KEYDOWN, VK_TAB, 0);   /* back to MODS */

            /* --- the filter ---------------------------------------------- */
            if (f == 100) { filterWas = g_ov.filter; SendMessageW(hwnd, WM_KEYDOWN, 'F', 0); }
            if (f == 102) filterMoved = (g_ov.filter != filterWas);
            if (f == 104 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\07-filtered.bmp", shotDir);
                if (shoot(path)) ok("wrote 07-filtered.bmp");
            }
            if (f == 106) {
                /* Back to `all`, so the mouse click below has a full list under
                 * it whatever the filter happened to leave visible. */
                for (int32_t k = g_ov.filter; k % AOWL_FILTER_COUNT; k++)
                    SendMessageW(hwnd, WM_KEYDOWN, 'F', 0);
            }

            /* --- the mouse, on the row button ---------------------------- */
            if (f == 110) {
                /* Computed from the header's own constants rather than written
                 * out: the panel is sized to the back buffer now, and a hard
                 * coded 522 was silently landing in the `decided by` column the
                 * moment the panel got wider. */
                /* ASKED, not re-derived: `aowl_ov_panel_rect` reports the
                 * rectangle the overlay actually drew. Recomputing it here
                 * from the constants is how this check once reported a
                 * button-geometry drift that did not exist, after the panel
                 * became movable and its width clamp changed. */
                int32_t k = aowl_ov_scale();
                float prx = 0.0f, pry = 0.0f, prw = 0.0f;
                aowl_ov_panel_rect(&prx, &pry, &prw, NULL);
                int32_t pw = (int32_t)prw;
                int32_t mouseRow = -1;
                mouseX = (int32_t)prx + pw - AOWL_OV_PAD - AOWL_OV_BTN_W / 2;
                mouseWas = -1;
                /* A row that has a button. A protected row draws `KEEP`
                 * instead, and clicking where its button would be correctly
                 * does nothing -- so aiming at one would test the wrong thing.
                 * (`j`, not `k`: `k` is the scale.) */
                for (int32_t j = 0; j < g_ov.modCount; j++) {
                    if (g_ov.mods[j].protectedRow) continue;
                    mouseWas = g_ov.mods[j].enabled;
                    strncpy(mouseGuid, g_ov.mods[j].guid, sizeof(mouseGuid) - 1);
                    mouseRow = j;
                    break;
                }
                /* The filter is back at `all` and the view is scrolled to the
                 * top, so the table index is the on-screen index. */
                mouseY = (int32_t)pry + AOWL_OV_HEAD_H + AOWL_OV_LINE_H
                         + (mouseRow < 0 ? 0 : mouseRow) * AOWL_OV_ROW_H
                         + AOWL_OV_ROW_H / 2;
                /* Panel units up to here; the window wants back-buffer pixels,
                 * and on a tall back buffer the panel is drawn at 2x or 3x. */
                mouseX *= k;
                mouseY *= k;
                SendMessageW(hwnd, WM_KEYDOWN, VK_HOME, 0);
                SendMessageW(hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(mouseX, mouseY));
            }
            if (f == 112) SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON,
                                       MAKELPARAM(mouseX, mouseY));
            if (f == 124 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\08-clicked.bmp", shotDir);
                if (shoot(path)) ok("wrote 08-clicked.bmp");
            }
            if (f == 126) {
                for (int32_t k = 0; k < g_ov.modCount; k++)
                    if (strcmp(g_ov.mods[k].guid, mouseGuid) == 0)
                        mouseMoved = (g_ov.mods[k].enabled != mouseWas);
            }

            /* --- SPACE on a protected row -------------------------------
             *
             * The gesture that used to unload the mod manager and take every
             * route with it. Both the manager and the panel refuse it now; this
             * checks the panel's half, which is the one that has to answer
             * without a round trip. Skipped when nothing protected is on
             * screen -- with no backend there are only host-pushed rows and
             * none of them is protected, which is itself correct. */
            if (f == 126) {
                protRow = -1;
                for (int32_t j = 0; j < g_ov.modCount; j++)
                    if (g_ov.mods[j].protectedRow && g_ov.mods[j].enabled) {
                        protRow = j;
                        protWas = g_ov.mods[j].enabled;
                        strncpy(protGuid, g_ov.mods[j].guid, sizeof(protGuid) - 1);
                        break;
                    }
                if (protRow >= 0) {
                    SendMessageW(hwnd, WM_KEYDOWN, VK_HOME, 0);
                    for (int32_t j = 0; j < protRow; j++)
                        SendMessageW(hwnd, WM_KEYDOWN, VK_DOWN, 0);
                }
            }
            if (f == 128 && protRow >= 0) SendMessageW(hwnd, WM_KEYDOWN, VK_SPACE, 0);
            if (f == 129 && protRow >= 0) {
                /* Read on the very next frame: no request went out, so there is
                 * nothing to wait for, and that immediacy is the point. */
                for (int32_t j = 0; j < g_ov.modCount; j++)
                    if (strcmp(g_ov.mods[j].guid, protGuid) == 0)
                        protHeld = (g_ov.mods[j].enabled == protWas) &&
                                   !g_ov.mods[j].pending &&
                                   g_ov.lastError[0] != 0;
            }

            /* --- the mouse on a protected row ---------------------------
             *
             * Two gestures, one row. Aimed with the header's own constants,
             * the same way the button click above is, so that a layout change
             * moves both together. The filter is back at `all` and the table
             * is scrolled to the top, so the table index is the screen index.
             *
             * Frames are spaced because a click is consumed by the *render*
             * thread inside the next build, not in the window procedure. */
            if (f == 131 && protRow >= 0) {
                /* ASKED, not re-derived: `aowl_ov_panel_rect` reports the
                 * rectangle the overlay actually drew. Recomputing it here
                 * from the constants is how this check once reported a
                 * button-geometry drift that did not exist, after the panel
                 * became movable and its width clamp changed. */
                int32_t k = aowl_ov_scale();
                float prx = 0.0f, pry = 0.0f, prw = 0.0f;
                aowl_ov_panel_rect(&prx, &pry, &prw, NULL);
                int32_t pw = (int32_t)prw;
                protMouseY = AOWL_OV_PANEL_Y + AOWL_OV_HEAD_H + AOWL_OV_LINE_H
                             + protRow * AOWL_OV_ROW_H + AOWL_OV_ROW_H / 2;
                /* Straight at the `KEEP` label, where every other row's button
                 * is. */
                protMouseX = AOWL_OV_PANEL_X + pw - AOWL_OV_PAD
                             - AOWL_OV_BTN_W / 2;
                protMouseX *= k;
                protMouseY *= k;
                SendMessageW(hwnd, WM_MOUSEMOVE, 0,
                             MAKELPARAM(protMouseX, protMouseY));
            }
            if (f == 133 && protRow >= 0)
                SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON,
                             MAKELPARAM(protMouseX, protMouseY));
            if (f == 136 && protRow >= 0) {
                protBtnMoved = 0;
                for (int32_t j = 0; j < g_ov.modCount; j++)
                    if (strcmp(g_ov.mods[j].guid, protGuid) == 0)
                        protBtnMoved = (g_ov.mods[j].enabled != protWas) ||
                                       g_ov.mods[j].pending;
                /* Now move the selection somewhere else, so that the row-click
                 * below has to actually move it back. Selecting a row that was
                 * already selected proves nothing. */
                SendMessageW(hwnd, WM_KEYDOWN, VK_HOME, 0);
                if (protRow == 0) SendMessageW(hwnd, WM_KEYDOWN, VK_DOWN, 0);
            }
            if (f == 138 && protRow >= 0) {
                /* The name column, well clear of where the button would be. */
                int32_t k = aowl_ov_scale();
                protMouseX = (AOWL_OV_PANEL_X + AOWL_OV_PAD + 60) * k;
                SendMessageW(hwnd, WM_MOUSEMOVE, 0,
                             MAKELPARAM(protMouseX, protMouseY));
            }
            if (f == 140 && protRow >= 0)
                SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON,
                             MAKELPARAM(protMouseX, protMouseY));
            if (f == 143 && protRow >= 0) {
                protRowSel = (g_ov.sel[AOWL_VIEW_MODS] == protRow);
                protRowMoved = 0;
                for (int32_t j = 0; j < g_ov.modCount; j++)
                    if (strcmp(g_ov.mods[j].guid, protGuid) == 0)
                        protRowMoved = (g_ov.mods[j].enabled != protWas) ||
                                       g_ov.mods[j].pending;
            }

            /* --- clearing an override ------------------------------------ */
            if (f == 145) SendMessageW(hwnd, WM_KEYDOWN, 'C', 0);
            if (f == 150 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\09-cleared.bmp", shotDir);
                if (shoot(path)) ok("wrote 09-cleared.bmp");
            }

            /* --- resize, mid-run ----------------------------------------- */
            if (f == 156) {
                /* The host must drop its own RTV; the overlay must drop its own
                 * from inside the ResizeBuffers hook. */
                ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
                ID3D11RenderTargetView_Release(rtv);
                rtv = NULL;
                winW = 800; winH = 520;
                HRESULT rr = IDXGISwapChain_ResizeBuffers(swap, 1, winW, winH,
                                                          DXGI_FORMAT_R8G8B8A8_UNORM, 0);
                resizeOk = SUCCEEDED(rr) ? 1 : 0;
                if (!resizeOk) printf("      ResizeBuffers -> 0x%08lX\n", (unsigned long)rr);
                if (!make_rtv()) bad("could not recreate the host's RTV after resize");
                scene_bind();
            }
            if (f == 168 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\10-resized.bmp", shotDir);
                if (shoot(path)) ok("wrote 10-resized.bmp");
            }

            if (f == 172) {
                /* `backendRow`, not `!hostPushed`. A guid can be both -- a mod
                 * the registry lists *and* the client host loaded is exactly
                 * the case the merge exists for -- and counting the negation
                 * undercounts by however many of those there are. */
                for (int32_t k = 0; k < g_ov.modCount; k++)
                    if (g_ov.mods[k].backendRow) backendRows++;
            }

            /* Everything from here to `frames` is left drawing so the frame
             * cost settles: the EWMA is 1/32 and the first eight drawn frames
             * are dropped, so a run that stops at 90 reports start-up. */
            /* Posted, not sent, and that is the point.
             *
             * `SendMessageW` calls the window procedure directly, so it proves
             * the subclass *body* works and nothing about whether the subclass
             * is on the path a real keystroke takes. A real key goes into the
             * thread's message queue and reaches a window procedure only
             * because `DispatchMessageW` -- the loop at the top of this
             * function -- sends it there, through whatever `SetWindowLongPtrW`
             * left in `GWLP_WNDPROC`. Posting the close exercises exactly that
             * path, so "the toggle key turned the panel on and off again"
             * below is evidence about the mechanism the game's own input uses
             * rather than about a function call.
             *
             * It is still not evidence about Tarkov: a subclass cannot see
             * `GetAsyncKeyState`, DirectInput or `GetRawInputBuffer` polling.
             * See "Input" in host/Aowlspt.Overlay/README.md. */
            /* Close and reopen, well before the end, so that the frame cost
             * on the title bar can be read in both states. Everything the
             * script gestures at is done by now. */
            if (f == 180) PostMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            if (f == 184) {
                if (aowl_ov_visible())
                    bad("INSERT did not close the panel at frame 180");
                PostMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            }
            /* --- ACT: the settings screen -----------------------------
             *
             * F2 into settings, walk the nav to the deep page, into a
             * depth-3 group, then type a search. Everything is read back off
             * the back buffer afterwards. Only meaningful with a backend --
             * without one there is no schema and every check says
             * INCONCLUSIVE rather than PASS. */
            /* The launch hint, read off the BACK BUFFER at both ends: up
             * while its state says 1, and gone once its state says 2. Neither
             * is asserted from the draw call, and `hintUpOk` staying -1 when
             * the toast never armed is INCONCLUSIVE, not a pass. */
            if (aowl_ov_hint_state() == 1 && hintUpOk < 0 && aowl_ov_visible())
                hintUpOk = check_hint_up();
            if (aowl_ov_hint_state() == 2 && hintUpOk > 0 && hintGoneOk < 0 &&
                aowl_ov_visible())
                hintGoneOk = check_hint_gone();

            if (f == 190 && port > 0) SendMessageW(hwnd, WM_KEYDOWN, VK_F2, 0);
            if (f == 194 && port > 0) {
                /* Find the deep page in the nav rather than assuming index 0:
                 * the nav is built from whatever the index served. */
                for (int32_t k = 0; k < g_ov.sPageCount; k++)
                    if (strcmp(g_ov.sPages[k].id, "aowl.deep") == 0) g_setPage = k;
                if (g_setPage >= 0) g_ov.selPage = g_setPage;
            }
            if (f == 206 && port > 0 && g_setPage >= 0) {
                /* Into a node three deep, the way a click gets there. */
                for (int32_t c = 0; c < g_ov.sCatCount; c++)
                    if (strcmp(g_ov.sCats[c].full, "Player/Health") == 0) {
                        g_ov.selCat = c;
                        g_ov.navOpen[c] = 1;
                        g_ov.selItem = g_ov.sCats[c].lo;
                        g_ov.topItem = g_ov.selItem;
                    }
            }
            if (f == 210 && port > 0) {
                groupTitlesOk = check_group_titles();
                crumbOk = check_breadcrumb();
                mutationOk = check_mutations();
                bandsOk = check_group_bands();
                bigBoxOk = check_search_prominent();
                selectedOk = check_one_selected("Health");
                if (shotDir) {
                    _snprintf(path, sizeof(path), "%s\\12-settings-tree.bmp", shotDir);
                    if (shoot(path)) ok("wrote 12-settings-tree.bmp");
                }
            }
            /* The search box, driven exactly as a player drives it: `/` to
             * focus, then characters. Nothing here writes `g_ov.search`. */
            if (f == 214 && port > 0) {
                g_ov.selCat = -1;
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_2, 0);    /* `/` */
            }
            if (f == 216 && port > 0) {
                /* `regener`, not `regen`, and the extra two letters are for
                 * the INSTRUMENT: the glyph decoder ignores any run shorter
                 * than OCR_MIN_RUN (6) so that it does not read noise as text,
                 * which makes a 5-character term invisible to it. Both terms
                 * match the same four rows. */
                SendMessageW(hwnd, WM_KEYDOWN, 'R', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'E', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'G', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'E', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'N', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'E', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'R', 0);
            }
            if (f == 220 && port > 0) SendMessageW(hwnd, WM_KEYDOWN, VK_RETURN, 0);
            if (f == 222 && port > 0) {
                /* ENTER unfocused the box; the term is still up and the rows
                 * on screen are the matches. */
                searchFocusOk = !g_ov.searchFocus && g_ov.search[0] != 0;
                searchOk = check_search();
                if (shotDir) {
                    _snprintf(path, sizeof(path), "%s\13-settings-search.bmp", shotDir);
                    if (shoot(path)) ok("wrote 13-settings-search.bmp");
                }
            }
            /* A term that matches NOTHING must produce zero rows and say so --
             * the opposite failure (a bad term silently showing everything) is
             * the one a `contains`-shaped filter makes. */
            if (f == 226 && port > 0) {
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_2, 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'Q', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'Q', 0);
                SendMessageW(hwnd, WM_KEYDOWN, 'Z', 0);
            }
            if (f == 230 && port > 0) {
                emptyTermOk = (g_ov.filtCount == 0);
                if (!emptyTermOk)
                    bad("a term matching nothing did not narrow the list");
                SendMessageW(hwnd, WM_KEYDOWN, VK_ESCAPE, 0);  /* clear */
            }
            if (f == 234 && port > 0) {
                clearedOk = (g_ov.search[0] == 0);
                if (!clearedOk) bad("ESC did not clear the search term");
                SendMessageW(hwnd, WM_KEYDOWN, VK_F2, 0);      /* back */
            }

            /* --- ACT: the window is a window ---------------------------
             *
             * Moved, resized, maximised and made solid -- and each one is
             * checked by reading the geometry the NEXT frame actually drew,
             * not the state we just wrote. */
            if (f == 238) {
                movedFromX = g_ov.panX; movedFromW = g_ov.panW;
                SendMessageW(hwnd, WM_KEYDOWN, VK_F11, 0);
            }
            if (f == 242) {
                maxOk = g_ov.panMax && aowl_ov_visible();
                if (!maxOk) bad("F11 did not maximise the panel");
                SendMessageW(hwnd, WM_KEYDOWN, VK_F11, 0);
            }
            if (f == 246) {
                restoreOk = !g_ov.panMax &&
                            g_ov.panX == movedFromX && g_ov.panW == movedFromW;
                if (!restoreOk)
                    bad("un-maximising did not restore the saved geometry");
                alphaWas = g_ov.panAlpha;
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_PLUS, 0);
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_PLUS, 0);
            }
            if (f == 248) {
                /* Solid, and it got there by the key rather than by a write. */
                alphaOk = (g_ov.panAlpha == 255 && g_ov.panAlpha != alphaWas);
                if (!alphaOk) bad("-/= did not drive the background to solid");
            }

            /* --- ACT: the tree collapses, and the keyboard is not swallowed --
             *
             * On frames of its own, after the search and window acts have
             * finished, because both leave state behind -- a term in the box
             * and a focused field -- and a check that runs on top of another
             * act`s leftovers is measuring the wrong screen. */
            if (f == 252) SendMessageW(hwnd, WM_KEYDOWN, VK_F2, 0);
            if (f == 254 && port > 0) {
                /* Nothing selected, two levels open: the one state in which the
                 * nav`s colours encode depth AND ONLY depth. */
                g_ov.search[0] = 0; g_ov.searchFocus = 0;
                g_ov.selCat = -1;
                for (int32_t c = 0; c < g_ov.sCatCount; c++)
                    g_ov.navOpen[c] = (strcmp(g_ov.sCats[c].full, "Player") == 0 ||
                                       strcmp(g_ov.sCats[c].full,
                                              "Player/Health") == 0);
            }
            if (f == 258 && port > 0) {
                depthOk = check_depth_visible();
                collapsePre = check_collapse_hides();
                indentMutOk = (panel_text_x(AOWL_OV_ERR, "Regeneration", 0,
                                            NULL) < 0) &&
                              (panel_text_x(AOWL_OV_TEXT,
                                            "no such string anywhere", 0,
                                            NULL) < 0);
                if (!indentMutOk)
                    bad("panel_text_x returned a position for text that is "
                        "not on screen -- every indent measurement is "
                        "worthless");
            }
            /* Close `Player`; its whole subtree must leave the NAV. */
            if (f == 260 && port > 0)
                for (int32_t c = 0; c < g_ov.sCatCount; c++)
                    if (strcmp(g_ov.sCats[c].full, "Player") == 0)
                        g_ov.navOpen[c] = 0;
            if (f == 264 && port > 0 && collapsePre > 0) {
                int gx = nav_text_x(AOWL_OV_FAINT, "Regeneration");
                int hx = nav_text_x(AOWL_OV_DIM, "Health");
                collapseOk = (gx < 0 && hx < 0);
                if (!collapseOk) {
                    char m2[160];
                    _snprintf(m2, sizeof(m2),
                              "closing a branch left its children in the nav "
                              "(Regeneration x=%d, Health x=%d)", gx, hx);
                    bad(m2);
                }
            }
            /* THE INPUT MODEL, both halves. Unfocused, `-` must reach the
             * panel and must NOT land in the term; focused, `-` must land in
             * the term and F10 must STILL work -- that is the whole reason the
             * opacity control is a function key. */
            if (f == 266 && port > 0) {
                keyAlphaWas = g_ov.panAlpha;
                keyFocusWas = g_ov.searchFocus;
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_MINUS, 0);
            }
            if (f == 268 && port > 0) {
                unfocusedKeyOk = !keyFocusWas &&
                                 g_ov.panAlpha != keyAlphaWas &&
                                 g_ov.search[0] == 0;
                if (!unfocusedKeyOk)
                    bad("with the search box unfocused, `-` did not reach the "
                        "panel, or leaked into the search term");
                keyAlphaWas = g_ov.panAlpha;
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_2, 0);   /* `/` focuses */
            }
            if (f == 270 && port > 0) {
                send_key(hwnd, VK_F10);   /* the REAL message: WM_SYSKEYDOWN */
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_MINUS, 0);
            }
            if (f == 272 && port > 0) {
                focusedKeyOk = g_ov.searchFocus &&
                               g_ov.panAlpha != keyAlphaWas &&
                               strchr(g_ov.search, 0x2D) != NULL;
                if (!focusedKeyOk)
                    bad("with the search box focused, F10 stopped working or "
                        "`-` did not reach the term");
                SendMessageW(hwnd, WM_KEYDOWN, VK_ESCAPE, 0);
                SendMessageW(hwnd, WM_KEYDOWN, VK_F2, 0);
            }

            /* ======================================================
             * ACT: THE SLIDERS, THE FILTER AND THE TREE'S FIRST LEVEL
             *
             * Back into settings mode on a clean screen. Everything below is
             * driven the way a player drives it -- real messages to the window
             * -- and read back off the buffer or off the fixture, never off the
             * state the gesture just wrote.
             * ====================================================== */
            if (f == 276 && port > 0) {
                SendMessageW(hwnd, WM_KEYDOWN, VK_F2, 0);
                g_ov.search[0] = 0; g_ov.searchFocus = 0; g_ov.selCat = -1;
            }
            if (f == 280 && port > 0) {
                /* Say what screen the checks below are about to be run on. A
                 * nav check run against the MOD MANAGER decodes nothing and
                 * reports INCONCLUSIVE, which reads like a decoder problem and
                 * is not one -- this line is the difference. */
                printf("      act: settings=%d page=%d/%d '%s' rows=%d "
                       "cats=%d visible=%d\n",
                       g_ov.settings, g_ov.selPage, g_ov.sPageCount,
                       g_ov.sItemsPage, g_ov.sItemCount, g_ov.sCatCount,
                       (int)g_ov.visible);
                navIndentOk  = check_nav_depth1_indent();
                unimplOk     = check_unimpl_hidden();
                rangesOk     = check_slider_ranges();
                deadPageOk   = check_dead_page_hidden(ask_fixture(L"/fetches"));
            }
            /* --- the drag. The mouse goes down on the slider track, MOVES
             *     across it for many frames, and comes up. One gesture. */
            if (f == 284 && port > 0) {
                for (int32_t i2 = 0; i2 < g_ov.sItemCount; i2++)
                    if (strcmp(g_ov.sItems[i2].key, "sliderok") == 0) {
                        for (int32_t c = 0; c < g_ov.sCatCount; c++)
                            if (strcmp(g_ov.sCats[c].full, "Numbers") == 0)
                                g_ov.selCat = c;
                        g_ov.selItem = i2;
                        g_ov.topItem = i2;
                        dragRow = i2;
                    }
                postsBefore  = posts_seen();
                writesBefore = g_ov.writeCount;
            }
            /* THE GESTURE IS A HELD ARROW KEY, not a synthetic mouse drag.
             *
             * A first attempt walked `g_ov.mx` across the panel with
             * `mouseHeld` set. It did not work and it was not a near miss: with
             * no `my` on the slider row the cursor was over whatever happened
             * to be under it, the `clickDown` that opened the gesture landed on
             * an unrelated control, and the checks after it were then reading a
             * screen the script had wandered off. Poking the cursor at
             * coordinates the harness computes ITSELF is exactly the
             * "re-derived the panel rect instead of asking" trap this file has
             * been caught in before.
             *
             * A held arrow is a real gesture, made through the window the way a
             * player makes it, and it runs the SAME path: `aowl_ov_s_adjust` ->
             * `aowl_ov_s_commit` -> the write slot. It is also the worse of the
             * two cases -- auto-repeat fires ~30 times a second indefinitely,
             * where a drag at least ends when the button comes up. What is NOT
             * covered here is the drag's own arming site; that shares one line
             * with this one and is stated as unverified rather than implied. */
            if (f >= 286 && f < 286 + kDragFrames && port > 0 && dragRow >= 0) {
                g_ov.selItem = dragRow;
                SendMessageW(hwnd, WM_KEYDOWN, VK_RIGHT, 0);
            }
            /* Well past AOWL_OV_WRITE_QUIET_MS at 16ms a frame, so the slot has
             * had every chance to flush -- "fewer writes" must not be measured
             * inside the window that is holding them. */
            if (f == 286 + kDragFrames + 40 && port > 0 && dragRow >= 0) {
                dragCoalOk = check_drag_coalesced(kDragFrames,
                                                  postsBefore, posts_seen(),
                                                  writesBefore, g_ov.writeCount);
            }
            /* --- click-to-type: SPACE opens the box, digits go in, ENTER
             *     stores. Then the page is re-fetched and the value is read
             *     back off the screen. */
            if (f == 286 + kDragFrames + 46 && port > 0 && dragRow >= 0) {
                g_ov.selItem = dragRow;
                SendMessageW(hwnd, WM_KEYDOWN, VK_SPACE, 0);
            }
            if (f == 286 + kDragFrames + 48 && port > 0 && dragRow >= 0) {
                typeBoxOpenOk = (g_ov.editItem == dragRow) && !g_ov.searchFocus;
                if (!typeBoxOpenOk)
                    bad("SPACE on a numeric row did not open the value box, "
                        "or left the search field focused as well");
                /* Clear the seeded value, then type 42. Eight backspaces, not
                 * twenty-four: the key ring is AOWL_OV_KEYS deep and a frame
                 * that overfills it drops the tail -- which would have been the
                 * two digits, and the check would have blamed the field. */
                for (int k2 = 0; k2 < 8; k2++)
                    SendMessageW(hwnd, WM_KEYDOWN, VK_BACK, 0);
                /* SIX digits, not two. "42" is under the decoder`s 6-glyph
                 * minimum, so "is it on screen" came back false about a value
                 * that was plainly rendered -- the instrument`s limit, not the
                 * panel`s. Six digits is also inside the row`s 0..999999. */
                SendMessageW(hwnd, WM_KEYDOWN, '5', 0);
                SendMessageW(hwnd, WM_KEYDOWN, '4', 0);
                SendMessageW(hwnd, WM_KEYDOWN, '3', 0);
                SendMessageW(hwnd, WM_KEYDOWN, '2', 0);
                SendMessageW(hwnd, WM_KEYDOWN, '1', 0);
                SendMessageW(hwnd, WM_KEYDOWN, '0', 0);
            }
            if (f == 286 + kDragFrames + 50 && port > 0 && dragRow >= 0) {
                /* A letter must NOT enter a numeric field. */
                SendMessageW(hwnd, WM_KEYDOWN, 'X', 0);
            }
            if (f == 286 + kDragFrames + 52 && port > 0 && dragRow >= 0) {
                numOnlyOk = (strcmp(g_ov.editBuf, "543210") == 0);
                if (!numOnlyOk) {
                    char m3[128];
                    _snprintf(m3, sizeof(m3),
                              "the number box accepted a letter: buffer is "
                              "'%s', expected '543210'", g_ov.editBuf);
                    bad(m3);
                }
                SendMessageW(hwnd, WM_KEYDOWN, VK_RETURN, 0);
            }
            /* Long enough for the flush, the POST and the page re-GET. */
            if (f == 286 + kDragFrames + 100 && port > 0 && dragRow >= 0)
                typedOk = check_typed_readback("543210");
            /* --- F8, and the fact that it works from a FOCUSED FIELD. */
            if (f == 286 + kDragFrames + 106 && port > 0) {
                SendMessageW(hwnd, WM_KEYDOWN, VK_OEM_2, 0);   /* focus search */
            }
            if (f == 286 + kDragFrames + 108 && port > 0) {
                f8FromFieldWas = g_ov.showUnimpl;
                f8FocusWas = g_ov.searchFocus;
                SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);
            }
            if (f == 286 + kDragFrames + 112 && port > 0) {
                f8FromFieldOk = f8FocusWas &&
                                (g_ov.showUnimpl != f8FromFieldWas);
                if (!f8FromFieldOk)
                    bad("F8 did not reach the panel with the search field "
                        "focused -- a shortcut a text field can eat");
                g_ov.search[0] = 0; g_ov.searchFocus = 0;
            }
            /* With F8 on, the rows that were hidden must be BACK -- the
             * negative in its mirror form. A filter that hides everything
             * forever passes "nothing unimplemented is shown" perfectly. */
            if (f == 286 + kDragFrames + 130 && port > 0) {
                static char t8[65536];
                panel_read_text(t8, (int)sizeof(t8), AOWL_OV_TEXT);
                if (!strstr(t8, "Cultist")) {
                    static char t8b[65536];
                    panel_read_text(t8b, (int)sizeof(t8b), AOWL_OV_DIM);
                    f8ShowsOk = strstr(t8b, "Cultist") != NULL;
                } else f8ShowsOk = 1;
                if (!f8ShowsOk)
                    bad("F8 is on but the not-implemented rows are still not "
                        "on screen -- the toggle only hides");
                SendMessageW(hwnd, WM_KEYDOWN, VK_F8, 0);   /* back to default */
            }
            if (f == 286 + kDragFrames + 150 && port > 0)
                newMutOk = check_new_mutations();
            /* THE OPACITY PAIR. On frames of its own and last, because it
             * drives the alpha to both bounds and leaves it mid-range -- a
             * check that runs on top of that is measuring a screen somebody
             * else's act moved. It pumps its own frames, so the loop counter
             * advances past `f` here; everything after it is `frames - N`. */
            if (f == 286 + kDragFrames + 160) {
                opacityOk = check_opacity_pair(hwnd, pump_frames);
                if (opacityOk)
                    opacityMutOk = check_opacity_mutation(hwnd, pump_frames);
            }

            if (f == 188) costLabelOk = check_cost_label(1);
            if (f == 250) costLabelOk = check_cost_label(0) && costLabelOk;

            if (f == frames - 6) PostMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            if (f == frames - 2 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\11-hidden.bmp", shotDir);
                if (shoot(path)) ok("wrote 11-hidden.bmp");
            }
            /* With a backend, frames have to take about as long as real ones:
             * the overlay's worker polls on a wall-clock timer and a run that
             * sprints through 300 frames in a second would check the panel
             * against one poll's worth of data. Without one there is nothing to
             * wait for. */
            Sleep(port > 0 ? 16 : 4);
        }
    }

    /* --- verdicts --- */
    {
        char why[256];
        aowl_ov_status(why, sizeof(why));
        printf("      status: %s\n", why);
    }
    /* The worker's own state, printed on every run. `queued` is the one to
     * watch: anything but zero means gestures were made and never reached the
     * far end, which against a live backend is a bug and against a dead one is
     * a regression in the refusal path. */
    printf("      worker: reachable=%ld everReached=%ld lastRequest=%ldms "
           "queued=%d\n      last gesture: %s\n",
           (long)g_ov.backendOk, (long)g_ov.everOk, (long)g_ov.lastRttMs,
           g_ov.cmdCount,
           g_ov.applyWhat[0] ? g_ov.applyWhat : "(none)");
    if (g_ov.lastError[0]) printf("      last error: %s\n", g_ov.lastError);
    if (g_ov.cmdCount == 0)
        ok("no gesture was left stranded in the worker's queue");
    else
        bad("gestures are still queued: the worker did not drain them, and a "
            "player would be looking at a row stuck at `~`");
    if (aowl_ov_frames() > 0) ok("the Present hook fired");
    else bad("the Present hook never fired");

    /* --- the settings screen, the window, and the launch hint ------------
     *
     * Three outcomes, never two. `-1` means the act was not attempted (no
     * backend, so no schema) and prints as INCONCLUSIVE: "I could not look" is
     * not a pass, and a green run with no backend used to be exactly that. */
    {
        struct { const char* name; int v; } verdicts[] = {
            { "every group on the page renders WITH A TITLE", groupTitlesOk },
            { "the header is a full breadcrumb to any depth", crumbOk },
            { "each nav check FAILS when the tree is broken (mutation proof)",
              mutationOk },
            { "a term matching a known setting returns rows, each showing WHERE",
              searchOk },
            { "ENTER leaves the search box with the term still applied",
              searchFocusOk },
            { "a term matching nothing returns nothing, not everything",
              emptyTermOk },
            { "ESC clears the search term", clearedOk },
            { "F11 maximises the panel", maxOk },
            { "un-maximising restores the saved geometry exactly", restoreOk },
            { "-/= drives the background all the way to solid", alphaOk },
            { "nav depth is VISIBLE: each level indents further and is drawn "
              "in its own colour", depthOk },
            { "a group is a BAND its rows sit below and inside", bandsOk },
            { "the search box is full-width and two lines tall", bigBoxOk },
            { "panel_text_x misses when the text is not there (mutation proof)",
              indentMutOk },
            { "EXACTLY ONE nav row renders selected, and it is the one clicked",
              selectedOk },
            { "closing a branch takes its children OFF SCREEN", collapseOk },
            { "unfocused, `-` reaches the panel and not the search term",
              unfocusedKeyOk },
            { "focused, F10 still works and `-` goes into the term",
              focusedKeyOk },
            { "the launch hint is ON SCREEN while it is up", hintUpOk },
            { "the launch hint is OFF SCREEN once it has expired", hintGoneOk },
            /* --- the slider / filter / tree act --- */
            { "NO nav row renders at the same x-offset as its own parent -- "
              "the FIRST level of nesting is indented too", navIndentOk },
            { "NO rendered row is implemented:false, and no group is left "
              "empty by hiding them", unimplOk },
            { "a page whose every row is unimplemented is absent from the nav "
              "AND was never fetched", deadPageOk },
            { "only a WELL-FORMED range draws a slider; a missing, inverted or "
              "unusable one falls back", rangesOk },
            { "a slider drag of 90 frames emits FEWER than 90 writes, and more "
              "than zero", dragCoalOk },
            { "SPACE opens the value box and takes focus from the search field",
              typeBoxOpenOk },
            { "the value box refuses a letter", numOnlyOk },
            { "a typed value is read back OVER THE WIRE unchanged", typedOk },
            { "F8 reaches the panel with a text field focused", f8FromFieldOk },
            { "F8 puts the hidden rows BACK on screen", f8ShowsOk },
            { "each new check FAILS when handed what it claims to detect "
              "(mutation proof)", newMutOk },
            { "F9 and F10 are a SYMMETRIC pair: N presses each way returns the "
              "RENDERED background to where it started, and both bounds are "
              "reachable", opacityOk },
            { "the opacity check FAILS when one direction is dead "
              "(mutation proof)", opacityMutOk },
        };
        size_t vi;
        for (vi = 0; vi < sizeof(verdicts) / sizeof(verdicts[0]); vi++) {
            if (verdicts[vi].v > 0) ok(verdicts[vi].name);
            else if (verdicts[vi].v < 0)
                printf("INCONCLUSIVE %s -- not attempted (no backend on this "
                       "run)\n", verdicts[vi].name);
            else bad(verdicts[vi].name);
        }
    }
    /* The launch hint. `hintFrames` is frames it was ACTUALLY DRAWN on, which
     * is the only number that distinguishes "shown then hidden" from "never\n     * shown" -- and `never shown` is INCONCLUSIVE for the auto-hide, not a
     * pass for it. */
    printf("      launch hint: enabled=%d state=%d drawnFrames=%d  %s\n",
           g_ov.hintEnabled, aowl_ov_hint_state(), aowl_ov_hint_frames(),
           g_ov.hintWhy[0] ? g_ov.hintWhy : "(the backend never served it)");
    if (g_ov.hintEnabled && aowl_ov_hint_frames() > 0)
        ok("the launch hint was drawn and then stopped being drawn");
    else if (!g_ov.hintEnabled)
        ok("the launch hint was never drawn, because the setting is off");
    else
        printf("INCONCLUSIVE launch hint: never drawn in %d frames -- the "
               "backend had not answered inside this run\n", aowl_ov_frames());

    if (printMismatches == 0) ok("context state identical before and after every Present");
    else { char m[96]; _snprintf(m, sizeof(m), "context state changed across %d Presents",
                                 printMismatches); bad(m); }

    if (headless) {
        if (drewPixels > 400) ok("the panel put pixels on the back buffer");
        else { char m[96]; _snprintf(m, sizeof(m),
                 "the panel drew %d panel-coloured pixels (expected > 400)", drewPixels);
               bad(m); }
        if (costLabelOk == -1)
            bad("the frame cost was never read off the title bar -- the "
                "close-and-reopen never happened, so that check proved "
                "nothing");
        else if (!costLabelOk)
            bad("the frame cost label after a reopen is wrong (reported above)");
        if (!legendChecked)
            bad("the legend was never read back off the screen -- the panel "
                "was not up at frame 35, so that check proved nothing");
        else if (!legendOk)
            bad("the legend readback failed (reported above)");
        if (resizeOk == 1) ok("ResizeBuffers succeeded with the overlay hooked");
        else bad("ResizeBuffers failed with the overlay hooked");
        if (aowl_ov_visible() == 0) ok("the toggle key turned the panel on and off again "
                                       "(the close was posted through the message queue, so "
                                       "the subclass is on the path DispatchMessage uses)");
        else bad("the panel did not close on the second toggle");

        /* --- the keyboard, which is the whole interface in a raid ---------
         *
         * Tarkov captures the cursor and reads the mouse through raw input. The
         * overlay integrates raw deltas into a cursor of its own, so the mouse
         * does work -- but the gesture a player can actually perform mid-raid
         * is a keypress, so the keyboard path is the one that has to be
         * checked rather than assumed. */
        if (keySelOk) ok("HOME and DOWN moved the cursor to the intended row");
        else bad("the arrow keys did not land the cursor where they were aimed");

        /* Sampled ten frames after the keypress rather than at the end of
         * the run: the list switch later re-resolves every row, and a mod
         * turned back on by a list is not evidence about what SPACE did.
         *
         * With no `--port` the correct behaviour is the opposite one: there is
         * no worker thread, so the overlay must refuse the gesture and say why
         * rather than flip the row and leave a `~` nothing can clear. */
        if (port > 0) {
            if (keyToggled)
                ok("SPACE toggled the selected row (or left it pending, which "
                   "is the honest state while no backend has answered)");
            else
                bad("SPACE on the selected row changed nothing at all");
        } else {
            if (!keyToggled && g_ov.lastError[0])
                ok("read-only: SPACE was refused with a reason rather than "
                   "flipping a row nothing could ever confirm");
            else
                bad("read-only: SPACE changed a row with no backend to confirm "
                    "it, which leaves a `~` that never clears");
        }

        if (tabbedToLists) ok("TAB moved to the LISTS view");
        else bad("TAB did not change view");
        if (tabbedRound) ok("TAB walked on through ISSUES to APPLY");
        else bad("TAB did not reach the APPLY view");
        if (filterMoved) ok("F cycled the mods filter");
        else bad("F did not change the filter");

        /* SPACE on a protected row: the gesture that used to unload the mod
         * manager and take every route with it. Both the manager and the panel
         * refuse it now, and this is the panel's half -- the one that has to
         * answer without a round trip, so that a protected row does not sit at
         * `~` for a second before nothing happens. */
        if (protRow >= 0) {
            if (protHeld)
                ok("SPACE on a protected row was refused on the spot, with a "
                   "reason, and the row did not move");
            else
                bad("SPACE on a protected row changed it or left it pending -- "
                    "the panel is about to ask the manager to unload the thing "
                    "that serves it");
        } else if (backendRows > 0) {
            /* `backendRows`, not `port > 0`: a port with nothing listening on
             * it is one of the configurations this file exists to check, and
             * there are no rows at all in it to be protected. The claim below
             * is only meaningful once a manager has actually answered. */
            /* Not a note any more. Every manager that can answer this panel
             * protects itself -- `isProtected` in `mods/manager/manager.nim`
             * always names `aowl.manager` -- so with a backend up, no protected
             * row on screen means the flag stopped being served or stopped
             * being read, and the panel is offering a working OFF button on the
             * mod that serves every route it reads. That used to print as a
             * line nobody looked at, on a run that passed. */
            bad("no row came back protected, but a backend answered: the "
                "manager always protects itself, so either it stopped sending "
                "`protected` or aowl_ov_read_panel stopped reading it -- and "
                "the panel now has an OFF button on the mod serving it");
        }

        /* The mouse half of the protected rule, both directions. */
        if (protRow >= 0) {
            if (protBtnMoved == 0)
                ok("a click where a protected row's button would be does "
                   "nothing -- there is a KEEP label there, not a button");
            else if (protBtnMoved > 0)
                bad("clicking a protected row's KEEP label toggled it");
            if (protRowSel > 0 && protRowMoved == 0)
                ok("a click on a protected row still selects it, so its reason "
                   "and `decided by` are readable");
            else if (protRowMoved > 0)
                bad("clicking the body of a protected row toggled it");
            else if (protRowSel == 0)
                bad("a click on a protected row did not select it -- the draw "
                   "loop is skipping the row-select hit test along with the "
                   "button, so the one row that most needs explaining is the "
                   "one row the mouse cannot reach");
        }

        /* The mouse is a supported gesture and it is the one that regressed
         * silently when the panel got wider -- a hard-coded x was landing in
         * the `decided by` column. With no backend the correct answer is the
         * refusal again, for the same reason as SPACE. */
        if (port > 0) {
            if (mouseMoved || mouseWas < 0)
                ok("the mouse click on a row button still toggles it");
            else
                bad("a click on the row button did nothing -- the button "
                    "geometry and the hit test have drifted apart");
        } else if (!mouseMoved) {
            ok("read-only: a click on a row button was refused too");
        } else {
            bad("read-only: a click changed a row with no backend to confirm it");
        }

        /* --- what a frame of this costs ----------------------------------
         *
         * Reported rather than asserted against a threshold. The number here is
         * a WARP software device on a CI-shaped machine and a real GPU is
         * faster; what a threshold would catch is the machine being busy, which
         * is not a bug in the overlay. What it is here for is that the figure
         * gets printed on every run, so a change that makes it ten times worse
         * is visible in the diff of a build log. */
        {
            char m[160];
            _snprintf(m, sizeof(m),
                      "      per frame with the panel open: %d ns average "
                      "(%ld ns laying out geometry, %ld ns of D3D11), "
                      "%d ns worst, %d frames drawn",
                      aowl_ov_frame_ns(), (long)g_ov.avgBuildNs,
                      (long)(aowl_ov_frame_ns() - g_ov.avgBuildNs),
                      aowl_ov_frame_ns_max(), g_ov.drawn);
            printf("%s\n", m);
            _snprintf(m, sizeof(m),
                      "      geometry rebuilt on %d of %d drawn frames (%d%%)",
                      g_ov.builds, g_ov.drawn,
                      g_ov.drawn ? (100 * g_ov.builds) / g_ov.drawn : 0);
            printf("%s\n", m);
            if (aowl_ov_frame_ns() > 0) ok("the frame cost was measured");
            else bad("no frame cost was measured; the panel never drew");
            /* The cache has to be doing something and it has to not be doing
             * everything. A hundred percent means the signature never settles
             * -- something that ticks on its own got into it -- and a rebuild
             * count that barely grows across a scripted run of keypresses and
             * mouse moves means it settled too hard and the panel is showing a
             * stale frame. */
            if (g_ov.drawn > 100) {
                if (g_ov.builds >= g_ov.drawn)
                    bad("the geometry cache never hit: the signature is moving "
                        "every frame");
                else if (g_ov.builds < 8)
                    bad("the geometry cache never missed across a run full of "
                        "keypresses; it is showing stale frames");
                else
                    ok("the geometry cache hits on quiet frames and misses when "
                       "something moves");
            }
        }

        /* Headroom in the one fixed buffer the panel can overrun. A dropped
         * quad is not a crash -- `aowl_ov_vert` refuses rather than grows,
         * because the render thread does not allocate -- it is a line of text
         * that silently is not there, which is the worst kind of wrong. */
        {
            char m[128];
            _snprintf(m, sizeof(m), "      busiest frame: %d of %d vertices",
                      g_ov.maxVtx, AOWL_OV_MAX_VERTS);
            printf("%s\n", m);
            if (g_ov.vtxDropped == 0) ok("no geometry was dropped by the cap");
            else {
                _snprintf(m, sizeof(m),
                          "%d vertices were dropped: AOWL_OV_MAX_VERTS is too "
                          "small and part of the panel did not draw",
                          g_ov.vtxDropped);
                bad(m);
            }
        }
    }

    /* --- the backend, when there is one ----------------------------------
     *
     * These are the checks that the reconciled schema is the one being read.
     * They are skipped without `--port` rather than faked: a run with no
     * backend is a legitimate configuration (the panel is read-only) and
     * asserting backend behaviour there would be asserting nothing. */
    if (headless && port > 0 && !g_ov.everOk) {
        /* The port was given and nothing ever answered on it. That is a
         * legitimate thing to test -- the run above checked the panel stayed
         * interactive and refused gestures with a reason -- but asserting the
         * manager's schema against a backend that is not there would be
         * asserting nothing, so it is said out loud and skipped. */
        char m[128];
        _snprintf(m, sizeof(m),
                  "      no backend ever answered on :%d, so the manager's "
                  "schema was not checked", port);
        printf("%s\n", m);
    } else if (headless && port > 0) {
        if (backendRows > 0) {
            char m[96];
            _snprintf(m, sizeof(m), "%d rows came from the backend's panel route",
                      backendRows);
            ok(m);
        } else {
            bad("no row came from the backend: the panel route was not read");
        }

        /* Everything below is a field that only `/aowlspt/mods/list`,
         * `/lists`, `/conflicts` or a change reply can fill in. A panel that
         * only read `/panel` would pass every check above and none of these. */
        {
            int32_t withReason = 0, withVerdict = 0, withFrom = 0;
            for (int32_t k = 0; k < g_ov.modCount; k++) {
                if (!g_ov.mods[k].backendRow) continue;
                if (g_ov.mods[k].reason[0]) withReason++;
                if (g_ov.mods[k].verdict[0]) withVerdict++;
                if (g_ov.mods[k].from[0]) withFrom++;
            }
            if (withReason == backendRows && withVerdict == backendRows) {
                ok("every backend row carries the manager's own verdict and "
                   "reason");
            } else {
                char m[128];
                _snprintf(m, sizeof(m),
                          "%d/%d rows have a reason and %d/%d a verdict",
                          withReason, backendRows, withVerdict, backendRows);
                bad(m);
            }
            /* `from` is legitimately empty for a mod no list mentions, so the
             * check is that *some* row has one -- that the `/list` route was
             * read at all. */
            if (withFrom > 0)
                ok("`decided by` is populated, so /aowlspt/mods/list was read "
                   "and merged with the panel rows");
            else
                bad("no row has a `from`: the /list route was never read, and "
                    "the panel cannot say which list decided anything");
        }

        if (g_ov.listCount > 0) {
            char m[128];
            int32_t active = 0, entries = 0;
            for (int32_t k = 0; k < g_ov.listCount; k++)
                if (g_ov.lists[k].active) active++;
            entries = g_ov.entryCount;
            _snprintf(m, sizeof(m),
                      "%d named lists read, %d active, %d entries across them",
                      g_ov.listCount, active, entries);
            ok(m);
            if (entries == 0)
                bad("the lists have no entries: the nested `entries` array was "
                    "not walked, which is exactly what the old brace-scanning "
                    "reader could not do");
        } else {
            /* Not a failure on a stand-in that does not serve /lists. It is
             * reported so a run against something that should is not silently
             * missing a whole view. */
            printf("      note: no lists were read (the backend served no "
                   "/aowlspt/mods/lists)\n");
        }

        if (listRow >= 0) {
            char m[160];
            int32_t nowActive = 0;
            for (int32_t k = 0; k < g_ov.listCount; k++)
                if (strcmp(g_ov.lists[k].id, listId) == 0) nowActive = g_ov.lists[k].active;
            _snprintf(m, sizeof(m), "      ENTER on list %s: active now %d",
                      listId, nowActive);
            printf("%s\n", m);
        }

        {
            char m[192];
            _snprintf(m, sizeof(m),
                      "      manager says: control=%s liveKnown=%d "
                      "results=%d(max %d) requested=%d deferred=%d restart=%d",
                      g_ov.control[0] ? g_ov.control : "?", g_ov.liveKnownAll,
                      g_ov.resultCount, sawResults, g_ov.applyRequested, g_ov.applyDeferred,
                      g_ov.applyRestart);
            printf("%s\n", m);
            if (sawResults > 0)
                ok("per-mod outcomes came back and reached the APPLY view");
            else
                bad("no per-mod outcome reached the panel: a toggle's `apply` "
                    "results were not read");
        }

        {
            int32_t at = -1;
            for (int32_t k = 0; k < g_ov.modCount; k++)
                if (strcmp(g_ov.mods[k].guid, keyGuid) == 0) { at = k; break; }
            if (at < 0) {
                bad("the toggled row vanished from the table");
            } else {
                AowlOvMod* m = &g_ov.mods[at];
                char line[224];
                _snprintf(line, sizeof(line),
                          "      toggled %s: enabled %d -> %d, live %d, "
                          "restart %d, pending %d, verdict %s",
                          m->guid, keyWas, m->enabled, m->loaded, m->restart,
                          m->pending, m->verdict);
                printf("%s\n", line);

                /* `restart` used to be a constant `1` on any clicked row; it is
                 * now whatever the manager answered. Either value is correct
                 * here -- what would not be is the field never moving off the
                 * host's default, or the row never coming back with a verdict
                 * at all. */
                if (m->verdict[0])
                    ok("the toggled row came back with the manager's verdict");
                else
                    bad("the toggled row has no verdict; the reply was not read");
            }
        }

        /* --- the other host ------------------------------------------------
         *
         * A row this process pushed in may be lowered by the backend only where
         * the backend's answer carries the *client host's* own word about that
         * guid. Without it the manager is the server side guessing about a
         * process it cannot see, and believing it greys out every client mod;
         * with it, it is the same host that pushed the row, answering again one
         * poll later, and refusing it leaves an unloaded mod reading `running
         * yes` for the rest of the session.
         *
         * `aowl.clientprobe` is in no backend fixture, so nothing can lower it.
         * `aowl.sway` is in both fixtures with a client record that says it is
         * not running, so it must come down. */
        {
            int32_t badly = 0, rightly = 0;
            for (size_t j = 0; j < sizeof(kPushed) / sizeof(kPushed[0]); j++) {
                AowlOvMod* m = NULL;
                if (!kPushed[j].live) continue;   /* the host said it was off */
                for (int32_t k = 0; k < g_ov.modCount; k++)
                    if (strcmp(g_ov.mods[k].guid, kPushed[j].guid) == 0)
                        m = &g_ov.mods[k];
                if (!m || m->loaded) continue;
                if (m->clientKnown) rightly++; else badly++;
            }
            if (badly > 0)
                bad("the backend lowered `loaded` on a row the host pushed in "
                    "without the client host having answered about it");
            else
                ok("no host-pushed row was greyed out on the manager's word "
                   "alone");
            if (rightly > 0)
                ok("a host-pushed row the client host reported as stopped was "
                   "lowered, so an unloaded mod stops reading `running yes`");
            else
                bad("no host-pushed row was lowered by a client record: the "
                    "fixture carries no clientLive for a pushed guid, so the "
                    "rule that lets one through is not being tested");
        }

        /* And the wrapper, which is the only thing that can tell one kind of
         * `unknown` from another. A fixture where every row has an answer, or
         * none does, cannot test either. */
        {
            char m[192];
            int32_t known = 0, quiet = 0, argued = 0;
            for (int32_t k = 0; k < g_ov.modCount; k++) {
                if (!g_ov.mods[k].backendRow) continue;
                if (g_ov.mods[k].clientKnown) {
                    known++;
                    if (g_ov.mods[k].clientLive != g_ov.mods[k].clientWant) argued++;
                } else quiet++;
            }
            _snprintf(m, sizeof(m),
                      "      the game says: host=%d session=%s seq=%d rows=%d "
                      "more=%d; %d row(s) answered, %d unknown, %d disagreeing",
                      g_ov.clientHost, g_ov.clientSession[0] ? g_ov.clientSession : "-",
                      g_ov.clientSeq, g_ov.clientRows, g_ov.clientMore,
                      known, quiet, argued);
            printf("%s\n", m);
            if (!g_ov.clientHost)
                bad("the panel body carried no client host at all, so nothing "
                    "below it was exercised");
            else if (known == 0)
                bad("no backend row carries the client host's answer");
            else if (quiet == 0)
                bad("every backend row carries an answer, so the panel's "
                    "`unknown` path has no row to draw and is not tested");
            else
                ok("the panel can tell a row the game answered about from one "
                   "it did not, and says which host and how much it has sent");
            if (argued > 0)
                ok("a row where the game disagrees with the switch is on screen, "
                   "so the `!` marker is drawn");
            else
                bad("no row disagrees with the game, so the `!` marker never "
                    "drew and the fixture cannot fail without it");
        }
    }

    aowl_ov_stop();
    ok("overlay stopped and unhooked");

    printf("%s\n", g_failures == 0 ? "\nall overlay host checks passed"
                                   : "\nsome overlay host checks failed");
    return g_failures == 0 ? 0 : 1;
}
