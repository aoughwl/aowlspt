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
 * Build:  see build.ps1 / README.md in host/Aowlspt.Overlay
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
    int headless = 0, frames = 240;
    const char* shotDir = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--headless") == 0) headless = 1;
        else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) frames = atoi(argv[++i]);
        else if (strcmp(argv[i], "--shot") == 0 && i + 1 < argc) shotDir = argv[++i];
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

    aowl_ov_set_mod("aowl.clientprobe", "clientprobe", "0.1.0", 1);
    aowl_ov_set_mod("aowl.sway", "SWAY", "1.4.2", 1);
    aowl_ov_set_mod("aowl.efmb", "EscapeFromMyBasement", "0.3.0", 0);
    aowl_ov_set_mod("aowl.loot", "LootRebalance", "2.0.1", 1);

    int printMismatches = 0, drewPixels = 0, resizeOk = -1;
    char path[512];

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
            /* A scripted run: toggle on, move the mouse over the third row's
             * button, click it, then resize. Every step goes through the real
             * window procedure the overlay installed. */
            if (f == 10) SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            if (f == 12 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\01-visible.bmp", shotDir);
                if (shoot(path)) ok("wrote 01-visible.bmp");
            }
            if (f == 13) {
                int n = count_overlay_pixels();
                drewPixels = n;
            }
            if (f == 20) {
                /* Row 2 (zero-based) sits at y = 60 + 30 + 2*22 + 11 = 145;
                 * its button is at x = 40 + 520 - 10 - 56 + 28 = 522. */
                SendMessageW(hwnd, WM_MOUSEMOVE, 0, MAKELPARAM(522, 145));
                SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(522, 145));
            }
            if (f == 24 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\02-clicked.bmp", shotDir);
                if (shoot(path)) ok("wrote 02-clicked.bmp");
            }
            if (f == 30) {
                /* The resize test. The host must drop its own RTV; the overlay
                 * must drop its own from inside the ResizeBuffers hook. */
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
            if (f == 40 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\03-resized.bmp", shotDir);
                if (shoot(path)) ok("wrote 03-resized.bmp");
            }
            if (f == 45) SendMessageW(hwnd, WM_KEYDOWN, VK_INSERT, 0);
            if (f == 50 && shotDir) {
                _snprintf(path, sizeof(path), "%s\\04-hidden.bmp", shotDir);
                if (shoot(path)) ok("wrote 04-hidden.bmp");
            }
            if (f == 55) break;
        }
    }

    /* --- verdicts --- */
    {
        char why[256];
        aowl_ov_status(why, sizeof(why));
        printf("      status: %s\n", why);
    }
    if (aowl_ov_frames() > 0) ok("the Present hook fired");
    else bad("the Present hook never fired");

    if (printMismatches == 0) ok("context state identical before and after every Present");
    else { char m[96]; _snprintf(m, sizeof(m), "context state changed across %d Presents",
                                 printMismatches); bad(m); }

    if (headless) {
        if (drewPixels > 400) ok("the panel put pixels on the back buffer");
        else { char m[96]; _snprintf(m, sizeof(m),
                 "the panel drew %d panel-coloured pixels (expected > 400)", drewPixels);
               bad(m); }
        if (resizeOk == 1) ok("ResizeBuffers succeeded with the overlay hooked");
        else bad("ResizeBuffers failed with the overlay hooked");
        if (aowl_ov_visible() == 0) ok("the toggle key turned the panel on and off again");
        else bad("the panel did not close on the second toggle");
    }

    aowl_ov_stop();
    ok("overlay stopped and unhooked");

    printf("%s\n", g_failures == 0 ? "\nall overlay host checks passed"
                                   : "\nsome overlay host checks failed");
    return g_failures == 0 ? 0 : 1;
}
