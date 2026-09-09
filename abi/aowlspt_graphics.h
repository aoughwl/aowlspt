/* aowlspt_graphics.h -- full-frame post-process for post-1.0 EFT (IL2CPP).
 *
 * ## What this is
 *
 * A ReShade-style, screen-space post-processing stack that runs entirely in the
 * native host, with no managed C#, no BepInEx, no Unity Material and no
 * AssetBundle. It hooks `IDXGISwapChain::Present` (the same DXGI vtable the
 * overlay hooks, captured the same proven way), and just before the real
 * Present it takes the finished back buffer, runs it through an HLSL pass
 * compiled at runtime against the game's own D3D11 device, and writes the
 * graded image back to the same back buffer.
 *
 * This is a SEPARATE concern from `aowlspt_overlay.h`. The overlay draws a UI
 * on top of the frame; this regrades the whole frame. The user's "never use the
 * UI overlay" rule is about UI and does not apply here -- but the two do share
 * the swap chain, see "Coexistence with the overlay" below.
 *
 * ## Why native D3D11 and not in-engine (the bridge)
 *
 * The original BepInEx mod attached a `MonoBehaviour` to the FPS Camera and did
 * the AgX blit in `OnRenderImage`, in linear HDR. That cannot be ported
 * literally to this build: IL2CPP with managed-code stripping cannot define a
 * new managed type (no `TonemapBehaviour`), and loading a `Shader` needs an
 * AssetBundle plus a chain of boxed `il2cpp_runtime_invoke` calls that the
 * bridge (`abi/aowlspt_bridge.h`, feat-il2cpp-bridge) does not provide -- it
 * gives "run this closure on the Unity main thread", not a render helper. So
 * the honest, working path is D3D11 over the back buffer. It is screen-space
 * only: we see the shipped LDR sRGB image, not the linear HDR scene, so AgX
 * here is a filmic *look* rather than a literal tonemapper replacement, and
 * depth effects (SSAO) are out until the in-engine path exists. See Post.hlsl.
 *
 * ## Safe by default
 *
 * Every entry point is guarded. If the vtable cannot be captured, if the device
 * cannot be reached, if a shader fails to compile, or if any resource creation
 * fails, the module latches `broken` and the Present detour becomes a straight
 * pass-through: the game renders exactly as it would with this module absent.
 * Nothing here writes to game memory; it only reads and rewrites the back
 * buffer it is handed. A failure is a missing effect, never a crash.
 *
 * ## Coexistence with the overlay
 *
 * Both modules detour Present through `aowl_hook_install` (a trampoline detour
 * on the actual dxgi Present code, not a vtable swap). Installing the graphics
 * hook AFTER the overlay chains them: graphics runs first (regrades the raw
 * game frame), then calls the trampoline which reaches the overlay (draws UI on
 * the graded image), then the real Present. That ordering -- grade the world,
 * then UI crisp on top -- is what you want, and it is achieved simply by
 * starting graphics after the overlay in the host boot sequence.
 *
 * RVAs: none. This module resolves nothing by offset; it is build-independent.
 */

#ifndef AOWLSPT_GRAPHICS_H
#define AOWLSPT_GRAPHICS_H

#define COBJMACROS
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <d3d11.h>
#include <dxgi.h>

/* The trampoline-detour engine the overlay uses. Header-only static code; this
 * module is its own translation unit (aowlgraphics.nim), so it gets its own
 * copy exactly as the overlay's TU does -- no link conflict. */
#include "aowlspt_detour.h"

/* d3dcompiler is loaded dynamically so a missing DLL is a degraded feature, not
 * a load failure. The one function we need. */
typedef HRESULT (WINAPI *AowlGfxD3DCompileFn)(
    LPCVOID, SIZE_T, LPCSTR, const void*, void*,
    LPCSTR, LPCSTR, UINT, UINT, ID3DBlob**, ID3DBlob**);

/* ================================================================== *
 * Parameters -- the mod-controllable grade, pushed from the mod via
 * call("aowlspt.host::gfx_apply", <json>) -> aowl_gfx_set_params_json.
 * Field order is documentation only; the cbuffer layout is fixed in
 * aowl_gfx_upload_cb below and must match Post.hlsl's cbuffer Params.
 * ================================================================== */
typedef struct AowlGfxParams {
    float enabled;
    float exposure;
    float contrast;
    float saturation;
    float temperature;
    float tint;
    float tonemapper;      /* 0 none, 1 AgX, 2 ACES */
    float tonemapStrength;
    float lift;
    float gamma;
    float gain;
    float shadows;
    float highlights;
    float sharpness;
    float vignette;
    float bloomStrength;
    float vignetteRadius;
    float bloom;           /* 0/1 enable the bloom pre-pass */
    float diag;            /* 1 = red-tint blit test */
    float raidOnly;        /* 1 = grade only in-raid, pass-through in the menu */
    /* --- look extensions (all LDR screen-space; see Post.hlsl) --- */
    float clarity;         /* local-contrast unsharp, 0..1  (4 extra taps) */
    float vibrance;        /* saturation weighted by 1-sat, 0..1 (0 ALU cost) */
    float shadowDetail;    /* toe re-lift after contrast, 0..1 */
    float grain;           /* animated film grain, shadow-weighted, 0..1 */
    float grainSize;       /* grain cell size in pixels, >=1 */
    float dither;          /* triangular-PDF dither in LSBs, 0..2 */
    float chroma;          /* radial chromatic aberration, 0..1 (2 extra taps) */
    float bloomThreshold;  /* bright-pass knee, 0..1 */
} AowlGfxParams;

static AowlGfxParams aowl_gfx_defaults(void) {
    AowlGfxParams p;
    memset(&p, 0, sizeof(p));
    p.enabled = 1.0f;
    p.exposure = 0.0f;
    p.contrast = 1.05f;
    p.saturation = 1.05f;
    p.temperature = 0.0f;
    p.tint = 0.0f;
    p.tonemapper = 1.0f;         /* AgX */
    p.tonemapStrength = 0.85f;
    p.lift = 0.0f;
    p.gamma = 1.0f;
    p.gain = 1.0f;
    p.shadows = 0.0f;
    p.highlights = 1.1f;
    p.sharpness = 0.35f;
    p.vignette = 0.18f;
    p.bloomStrength = 0.35f;
    p.vignetteRadius = 1.0f;
    p.bloom = 1.0f;
    p.diag = 0.0f;
    p.raidOnly = 1.0f;           /* menu stays stock by default */
    p.clarity = 0.25f;
    p.vibrance = 0.30f;
    p.shadowDetail = 0.25f;
    p.grain = 0.15f;
    p.grainSize = 1.5f;
    p.dither = 1.0f;             /* on by default: it costs ~nothing and it is
                                  * the only thing that kills 8-bit banding in
                                  * dark interiors, which is most of Tarkov */
    p.chroma = 0.0f;             /* off: tasteful means opt-in */
    p.bloomThreshold = 0.70f;
    return p;
}

/* ================================================================== *
 * State
 * ================================================================== */
typedef struct AowlGfxState {
    volatile LONG started;
    volatile LONG broken;
    volatile LONG inPresent;         /* re-entrancy guard */

    CRITICAL_SECTION cs;             /* guards params */
    AowlGfxParams    params;

    /* Raid-state gate. `inRaid` is pushed by the host from the backend's poll
     * signal (definitive: the tarkov mod knows raid start/end). `gateAmount`
     * ramps 0..1 toward the gate target on the render thread so the effect
     * fades in/out over a few frames instead of popping. */
    volatile LONG    inRaid;
    float            gateAmount;

    /* hooks */
    void* presentHook;
    void* resizeHook;
    void* presentOrig;               /* trampoline to the real Present */
    void* resizeOrig;

    /* device, resolved lazily from the first live swap chain */
    IDXGISwapChain*         swap;
    ID3D11Device*           dev;
    ID3D11DeviceContext*    ctx;

    /* pipeline objects (device lifetime) */
    ID3D11VertexShader*     vs;
    ID3D11PixelShader*      psMain;
    ID3D11PixelShader*      psBright;
    ID3D11PixelShader*      psBlur;
    ID3D11SamplerState*     samp;
    ID3D11Buffer*           cb;
    ID3D11BlendState*       blendOff;
    ID3D11DepthStencilState* depthOff;
    ID3D11RasterizerState*  rast;

    /* size-dependent objects */
    UINT bbW, bbH;
    ID3D11RenderTargetView* bbRtv;    /* view on the back buffer */
    ID3D11Texture2D*        sceneCopy; /* CopyResource target, sampleable */
    ID3D11ShaderResourceView* sceneSrv;
    /* bloom scratch at half res */
    ID3D11Texture2D*        bloomA;
    ID3D11RenderTargetView* bloomARtv;
    ID3D11ShaderResourceView* bloomASrv;
    ID3D11Texture2D*        bloomB;
    ID3D11RenderTargetView* bloomBRtv;
    ID3D11ShaderResourceView* bloomBSrv;
    ID3D11ShaderResourceView* blackSrv; /* 1x1 black, bound to t1 when bloom off */
    DXGI_FORMAT             bbFormat;

    /* diagnostics */
    int32_t frames;
    int32_t deviceReady;
    char    status[256];

    /* --- GPU cost measurement (timestamp queries) -------------------
     * The brief asks for a NUMBER, and a CPU-side stopwatch around a D3D11
     * submit measures driver bookkeeping, not the pass. So: a disjoint +
     * two timestamps, collected non-blocking on a LATER frame. While a
     * query set is in flight we do not re-issue, so this samples
     * periodically rather than every frame -- which is the point (issuing
     * timestamps every frame is itself a cost). `gpuMs` is the last
     * successful measurement; 0 means "never measured", NOT "free". */
    ID3D11Query* qDisjoint;
    ID3D11Query* qT0;
    ID3D11Query* qT1;
    int          qInFlight;
    float        gpuMs;
    int32_t      gpuSamples;

    /* --- depth-buffer probe (see the SSAO note in the README) --------
     * Free: aowl_gfx_save already asks OMGetRenderTargets for the DSV bound
     * at Present. If a scene depth texture is still bound there AND it was
     * created BIND_SHADER_RESOURCE, depth effects are reachable with no new
     * hook at all. Recorded once, verbatim, so the answer is a measurement
     * and not an opinion. */
    int          depthProbed;
    char         depthNote[160];

    /* runtime shader compiler */
    HMODULE d3dcompiler;
    AowlGfxD3DCompileFn compile;
} AowlGfxState;

static AowlGfxState g_gfx;

/* One-time bring-up of the params critical section (and the default grade).
 *
 * The graphics *mod* pushes its grade at its own load time via
 * call("aowlspt.host::gfx_apply", ...), and the host loads mods (mods' onLoad
 * runs) BEFORE it calls aowl_gfx_start_driven / aowl_gfx_start. So a
 * `gfx_apply` -> aowl_gfx_set_params_json can reach `g_gfx.cs` before `start`
 * ran InitializeCriticalSection on it. Entering a zero-initialised
 * CRITICAL_SECTION is undefined (a zeroed LockCount reads as "held", so the
 * caller waits on a NULL semaphore and can hang) -- reproducibly, on some
 * builds. So every entry point that touches `g_gfx.cs` ensures it exists first,
 * exactly once, race-free. Defaults are seeded here too, so a grade the mod
 * pushed before `start` survives (start no longer re-clobbers it). */
static INIT_ONCE g_gfx_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK aowl_gfx_once_cb(PINIT_ONCE o, PVOID param, PVOID* ctx) {
    (void)o; (void)param; (void)ctx;
    InitializeCriticalSection(&g_gfx.cs);
    g_gfx.params = aowl_gfx_defaults();
    return TRUE;
}
static void aowl_gfx_ensure_init(void) {
    InitOnceExecuteOnce(&g_gfx_once, aowl_gfx_once_cb, NULL, NULL);
}

/* The default HLSL, embedded so the module always has something to run even if
 * the on-disk shader file is missing. Kept byte-identical in spirit to
 * mods/graphics/shaders/Post.hlsl; that file is the source of truth for edits.
 * (A future revision can load an override from disk; for now this is the one
 * that ships and it is guaranteed present.) */
static const char* AOWL_GFX_HLSL =
"cbuffer Params : register(b0){float _Enabled;float _Exposure;float _Contrast;float _Saturation;"
"float _Temperature;float _Tint;float _Tonemapper;float _TonemapStrength;"
"float _Lift;float _Gamma;float _Gain;float _Shadows;"
"float _Highlights;float _Sharpness;float _Vignette;float _BloomStrength;"
"float2 _TexelSize;float _VignetteRadius;float _Diag;"
"float _GateAmount;float _Time;float _Clarity;float _Vibrance;"
"float _ShadowDetail;float _Grain;float _GrainSize;float _Dither;"
"float _Chroma;float _BloomThreshold;float2 _Res;}\n"
"Texture2D _Source:register(t0);Texture2D _Bloom:register(t1);SamplerState _Samp:register(s0);\n"
"struct VSOut{float4 pos:SV_POSITION;float2 uv:TEXCOORD0;};\n"
"VSOut VSMain(uint id:SV_VertexID){VSOut o;o.uv=float2((id<<1)&2,id&2);"
"o.pos=float4(o.uv*float2(2,-2)+float2(-1,1),0,1);return o;}\n"
"float3 S2L(float3 c){return c<=0.04045?c/12.92:pow((c+0.055)/1.055,2.4);}\n"
"float3 L2S(float3 c){c=saturate(c);return c<=0.0031308?c*12.92:1.055*pow(c,1.0/2.4)-0.055;}\n"
"float Luma(float3 c){return dot(c,float3(0.2126,0.7152,0.0722));}\n"
"float Hash21(float2 p){p=frac(p*float2(443.8975,441.4236));p+=dot(p,p.yx+19.19);"
"return frac((p.x+p.y)*p.x);}\n"
"static const float3x3 AgXin=float3x3(0.842479062253094,0.0784335999999992,0.0792237451477643,"
"0.0423282422610123,0.878468636469772,0.0791661274605434,"
"0.0423756549057051,0.0784336,0.879142973793104);\n"
"static const float3x3 AgXout=float3x3(1.19687900512017,-0.0980208811401368,-0.0990297440797205,"
"-0.0528968517574562,1.15190312990417,-0.0989611768448433,"
"-0.0529716355144438,-0.0980434501171241,1.15107367264116);\n"
"float3 AgXc(float3 x){float3 x2=x*x;float3 x4=x2*x2;"
"return 15.5*x4*x2-40.14*x4*x+31.96*x4-6.868*x2*x+0.4298*x2+0.1191*x-0.00232;}\n"
"float3 AgX(float3 c){const float e0=-12.47393;const float e1=4.026069;"
"c=mul(AgXin,c);c=clamp(log2(max(c,1e-10)),e0,e1);c=(c-e0)/(e1-e0);c=AgXc(c);c=mul(AgXout,c);return saturate(c);}\n"
"float3 ACES(float3 x){return saturate((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14));}\n"
"float3 WB(float3 c,float t,float ti){float3 g=float3(1.0+t*0.20+ti*0.05,1.0-ti*0.10,1.0-t*0.20+ti*0.05);return c*g;}\n"
"float3 LGG(float3 c,float l,float gp,float gn){c=c*gn+l;c=max(c,0.0);c=pow(c,max(1.0/max(gp,1e-3),1e-3));return c;}\n"
/* ---- CAS: unchanged AMD-style contrast-adaptive sharpen. Adaptive by
 * construction, so it does not ring on already-crisp edges the way a fixed
 * unsharp mask does -- that is why it is the sharpener here and why the
 * clarity pass below deliberately works at a much wider radius instead of
 * stacking a second sharpen on the same frequencies. */
"float3 CAS(float2 uv,float3 mid,float amt){if(amt<=0.0001)return mid;float2 t=_TexelSize;"
"float3 a=_Source.Sample(_Samp,uv+float2(0,-t.y)).rgb;float3 b=_Source.Sample(_Samp,uv+float2(-t.x,0)).rgb;"
"float3 d=_Source.Sample(_Samp,uv+float2(t.x,0)).rgb;float3 e=_Source.Sample(_Samp,uv+float2(0,t.y)).rgb;"
"float3 mn=min(mid,min(min(a,b),min(d,e)));float3 mx=max(mid,max(max(a,b),max(d,e)));"
"float3 amp=sqrt(saturate(min(mn,1.0-mx)/max(mx,1e-4)));float w=-amp*(amt*0.2+0.05);"
"return saturate((mid+(a+b+d+e)*w)/(1.0+4.0*w));}\n"
/* ---- Clarity: midtone local contrast (unsharp against a wide 4-tap low
 * pass). This is the knob that makes a flat, hazy Tarkov frame read as
 * three-dimensional. Masked to peak at mid grey and fall to zero at both
 * ends, so it cannot crush blacks or blow highlights. 4 extra taps. */
"float3 Clarity(float2 uv,float3 c,float amt){if(amt<=0.0001)return c;"
"float2 t=_TexelSize*7.0;"
"float3 lo=_Source.Sample(_Samp,uv+float2( t.x, t.y)).rgb;"
"lo+=_Source.Sample(_Samp,uv+float2(-t.x, t.y)).rgb;"
"lo+=_Source.Sample(_Samp,uv+float2( t.x,-t.y)).rgb;"
"lo+=_Source.Sample(_Samp,uv+float2(-t.x,-t.y)).rgb;lo*=0.25;"
"float l=Luma(c);float dl=l-Luma(lo);float mask=1.0-abs(l*2.0-1.0);"
"return saturate(c+dl*amt*1.6*mask);}\n"
/* ---- Vibrance: saturation weighted by (1 - existing saturation). Grey,
 * washed-out things gain; already-saturated things (foliage, flares, a hit
 * marker) do not, so the frame gains colour separation without the neon
 * foliage a flat saturation multiplier gives. */
"float3 Vibrance(float3 c,float amt){if(abs(amt)<=0.0001)return c;"
"float mx=max(c.r,max(c.g,c.b));float mn=min(c.r,min(c.g,c.b));"
"float sat=saturate(mx-mn);float l=Luma(c);"
"return lerp(l.xxx,c,1.0+amt*(1.0-sat));}\n"
/* ---- Chromatic aberration: radial, red/blue only, exactly zero at the
 * screen centre so it never smears what you are aiming at. Off by default;
 * tasteful means opt-in. 2 extra taps. */
"float3 Chroma(float2 uv,float3 c,float amt){if(amt<=0.0001)return c;"
"float2 d=(uv-0.5)*amt*0.0035;"
"c.r=_Source.Sample(_Samp,uv+d).r;c.b=_Source.Sample(_Samp,uv-d).b;return c;}\n"
"float4 PSMain(VSOut i):SV_Target{float3 src=_Source.Sample(_Samp,i.uv).rgb;"
"if(_Enabled<0.5)return float4(src,1.0);if(_Diag>0.5)return float4(lerp(src,float3(1,0,0),0.5),1.0);"
"float3 c=CAS(i.uv,src,_Sharpness);"
"c=Clarity(i.uv,c,_Clarity);"
"c=Chroma(i.uv,c,_Chroma);"
"c=S2L(c);c*=exp2(_Exposure);"
"float hl=Luma(c);c*=lerp(1.0,1.0/max(_Highlights,0.01),saturate(hl-0.5)*(1.0-1.0/max(_Highlights,1.0)));"
"c+=_Shadows;c=WB(c,_Temperature,_Tint);float3 bl=_Bloom.Sample(_Samp,i.uv).rgb;c+=bl*_BloomStrength;"
"float3 m=c;if(_Tonemapper>1.5)m=ACES(c);else if(_Tonemapper>0.5)m=AgX(c);c=lerp(c,m,saturate(_TonemapStrength));c=saturate(c);"
"c=LGG(c,_Lift,_Gamma,_Gain);"
/* Contrast around 18% grey, then re-lift ONLY the toe. A straight contrast
 * multiply is exactly what crushes the shadow detail you need to see a
 * player standing in a doorway; _ShadowDetail buys that back without
 * lifting the whole image into milk the way a global `lift` does. */
"float3 pre=c;c=(c-0.18)*_Contrast+0.18;c=max(c,0.0);"
"float3 toe=1.0-smoothstep(0.0,0.14,pre);c+=toe*_ShadowDetail*0.045;"
"float l=Luma(c);c=lerp(l.xxx,c,_Saturation);"
"c=Vibrance(c,_Vibrance);"
"float2 dd=i.uv-0.5;float vig=1.0-_Vignette*smoothstep(_VignetteRadius*0.5,_VignetteRadius,length(dd)*1.4142);c*=saturate(vig);"
"float3 outc=L2S(c);"
/* Grain: animated, weighted toward the shadows -- which is both where real
 * film grain lives and where 8-bit banding lives, so one effect does two
 * jobs at once. */
"if(_Grain>0.0001){float2 gp=floor(i.uv*_Res/max(_GrainSize,1.0))+floor(_Time*24.0)*17.0;"
"float n=Hash21(gp)-0.5;float w=1.0-smoothstep(0.0,0.55,Luma(outc));"
"outc=saturate(outc+n*_Grain*0.09*(0.25+w));}\n"
/* Dither: triangular-PDF noise at ~1 LSB before the 8-bit write. The
 * cheapest real win in the stack -- every gradient built in linear above is
 * quantised on the way out, and dark Tarkov interiors are almost entirely
 * gradient. */
"if(_Dither>0.0001){float2 dp=i.uv*_Res;"
"float n1=Hash21(dp+_Time);float n2=Hash21(dp+_Time+41.7);"
"outc=saturate(outc+(n1-n2)*(_Dither/255.0));}\n"
"return float4(lerp(src,outc,_GateAmount),1.0);}\n"
"float4 PSBright(VSOut i):SV_Target{float3 c=S2L(_Source.Sample(_Samp,i.uv).rgb);float l=Luma(c);"
"return float4(c*smoothstep(_BloomThreshold,_BloomThreshold+0.35,l),1.0);}\n"
"float4 PSBlur(VSOut i):SV_Target{float2 dir=_TexelSize;float3 s=_Source.Sample(_Samp,i.uv).rgb*0.227027;"
"float2 o1=dir*1.3846153846;float2 o2=dir*3.2307692308;"
"s+=_Source.Sample(_Samp,i.uv+o1).rgb*0.3162162162;s+=_Source.Sample(_Samp,i.uv-o1).rgb*0.3162162162;"
"s+=_Source.Sample(_Samp,i.uv+o2).rgb*0.0702702703;s+=_Source.Sample(_Samp,i.uv-o2).rgb*0.0702702703;return float4(s,1.0);}\n";

/* ---------------------------------------------------------------- utils */

static void aowl_gfx_note(const char* s) {
    strncpy(g_gfx.status, s, sizeof(g_gfx.status) - 1);
    g_gfx.status[sizeof(g_gfx.status) - 1] = 0;
}
static void aowl_gfx_fail(const char* why) {
    InterlockedExchange(&g_gfx.broken, 1);
    aowl_gfx_note(why);
}

static int32_t aowl_gfx_running(void) { return g_gfx.started && !g_gfx.broken; }
/* Measured GPU milliseconds for the whole post chain, x1000 so it crosses the
 * int32 host boundary without a float. -1 = never measured (which is NOT the
 * same as "free"). */
static int32_t aowl_gfx_gpu_us(void) {
    return g_gfx.gpuSamples ? (int32_t)(g_gfx.gpuMs * 1000.0f) : -1;
}
static int32_t aowl_gfx_frames(void)  { return g_gfx.frames; }
static int32_t aowl_gfx_depth_note(char* buf, int32_t cap);

/* The status line the host logs. It carries the two things that must never be
 * guessed at: the MEASURED GPU cost of the whole post chain, and the depth
 * probe verdict. Both say plainly when they have no answer -- "not measured"
 * and "not probed yet" are distinct from a number and from a no. */
static int32_t aowl_gfx_status(char* buf, int32_t cap) {
    if (!buf || cap <= 0) return 0;
    char depth[160];
    aowl_gfx_depth_note(depth, (int32_t)sizeof(depth));
    int32_t us = aowl_gfx_gpu_us();
    char line[640];
    if (us >= 0)
        _snprintf(line, sizeof(line) - 1, "%s | post %d.%03d ms GPU (measured, %d samples) | %s",
                  g_gfx.status, us / 1000, us % 1000, (int)g_gfx.gpuSamples, depth);
    else
        _snprintf(line, sizeof(line) - 1, "%s | post GPU cost NOT MEASURED (no timestamp query yet) | %s",
                  g_gfx.status, depth);
    line[sizeof(line) - 1] = 0;
    int32_t n = (int32_t)strlen(line);
    if (n >= cap) n = cap - 1;
    memcpy(buf, line, (size_t)n);
    buf[n] = 0;
    return n;
}

static void aowl_gfx_set_params(const AowlGfxParams* p) {
    if (!p) return;
    aowl_gfx_ensure_init();
    EnterCriticalSection(&g_gfx.cs);
    g_gfx.params = *p;
    LeaveCriticalSection(&g_gfx.cs);
}

/* Minimal flat-JSON number reader: finds "key" and parses the number after the
 * next colon. Good enough for the compact {"key":num,...} the mod sends; on any
 * miss it leaves the field at its previous (default) value. */
static int aowl_gfx_jnum(const char* json, const char* key, float* out) {
    char pat[64];
    int kl = (int)strlen(key);
    if (kl > 60) return 0;
    pat[0] = '"';
    memcpy(pat + 1, key, (size_t)kl);
    pat[kl + 1] = '"';
    pat[kl + 2] = 0;
    const char* p = strstr(json, pat);
    if (!p) return 0;
    p += kl + 2;
    while (*p && *p != ':') p++;
    if (*p != ':') return 0;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    /* accept true/false as 1/0 for the bool-ish fields */
    if (!strncmp(p, "true", 4))  { *out = 1.0f; return 1; }
    if (!strncmp(p, "false", 5)) { *out = 0.0f; return 1; }
    char* end = NULL;
    double v = strtod(p, &end);
    if (end == p) return 0;
    *out = (float)v;
    return 1;
}

static void aowl_gfx_set_params_json(const char* json) {
    if (!json) return;
    aowl_gfx_ensure_init();
    AowlGfxParams p;
    EnterCriticalSection(&g_gfx.cs);
    p = g_gfx.params;                 /* start from current, patch what's present */
    LeaveCriticalSection(&g_gfx.cs);
    aowl_gfx_jnum(json, "enabled",         &p.enabled);
    aowl_gfx_jnum(json, "exposure",        &p.exposure);
    aowl_gfx_jnum(json, "contrast",        &p.contrast);
    aowl_gfx_jnum(json, "saturation",      &p.saturation);
    aowl_gfx_jnum(json, "temperature",     &p.temperature);
    aowl_gfx_jnum(json, "tint",            &p.tint);
    aowl_gfx_jnum(json, "tonemapper",      &p.tonemapper);
    aowl_gfx_jnum(json, "tonemapStrength", &p.tonemapStrength);
    aowl_gfx_jnum(json, "lift",            &p.lift);
    aowl_gfx_jnum(json, "gamma",           &p.gamma);
    aowl_gfx_jnum(json, "gain",            &p.gain);
    aowl_gfx_jnum(json, "shadows",         &p.shadows);
    aowl_gfx_jnum(json, "highlights",      &p.highlights);
    aowl_gfx_jnum(json, "sharpness",       &p.sharpness);
    aowl_gfx_jnum(json, "vignette",        &p.vignette);
    aowl_gfx_jnum(json, "bloomStrength",   &p.bloomStrength);
    aowl_gfx_jnum(json, "vignetteRadius",  &p.vignetteRadius);
    aowl_gfx_jnum(json, "bloom",           &p.bloom);
    aowl_gfx_jnum(json, "diag",            &p.diag);
    aowl_gfx_jnum(json, "raidOnly",        &p.raidOnly);
    aowl_gfx_jnum(json, "clarity",         &p.clarity);
    aowl_gfx_jnum(json, "vibrance",        &p.vibrance);
    aowl_gfx_jnum(json, "shadowDetail",    &p.shadowDetail);
    aowl_gfx_jnum(json, "grain",           &p.grain);
    aowl_gfx_jnum(json, "grainSize",       &p.grainSize);
    aowl_gfx_jnum(json, "dither",          &p.dither);
    aowl_gfx_jnum(json, "chroma",          &p.chroma);
    aowl_gfx_jnum(json, "bloomThreshold",  &p.bloomThreshold);
    aowl_gfx_set_params(&p);
}

/* The raid-state gate signal, pushed by the host from the backend poll. 1 =
 * in a raid (grade), 0 = menu / loading / unknown (pass-through when raidOnly).
 * A plain interlocked write; the render thread reads it each frame. */
static void aowl_gfx_set_in_raid(int32_t on) {
    InterlockedExchange(&g_gfx.inRaid, on ? 1 : 0);
}
static int32_t aowl_gfx_in_raid(void) { return g_gfx.inRaid; }

/* ---------------------------------------------------------------- COM GUIDs */
static const GUID AOWL_GFX_IID_Tex2D =
    { 0x6f15aaf2, 0xd208, 0x4e89, { 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/* ---------------------------------------------------------------- shaders */
static int aowl_gfx_compile_ps(const char* entry, ID3D11PixelShader** out) {
    ID3DBlob* code = NULL;
    ID3DBlob* err = NULL;
    HRESULT hr = g_gfx.compile(AOWL_GFX_HLSL, strlen(AOWL_GFX_HLSL), "Post.hlsl",
                               NULL, NULL, entry, "ps_5_0", 0, 0, &code, &err);
    if (err) ID3D10Blob_Release(err);
    if (FAILED(hr) || !code) return 0;
    hr = ID3D11Device_CreatePixelShader(g_gfx.dev, ID3D10Blob_GetBufferPointer(code),
                                        ID3D10Blob_GetBufferSize(code), NULL, out);
    ID3D10Blob_Release(code);
    return SUCCEEDED(hr);
}

static int aowl_gfx_make_pipeline(void) {
    /* vertex shader */
    ID3DBlob* vsc = NULL; ID3DBlob* err = NULL;
    HRESULT hr = g_gfx.compile(AOWL_GFX_HLSL, strlen(AOWL_GFX_HLSL), "Post.hlsl",
                               NULL, NULL, "VSMain", "vs_5_0", 0, 0, &vsc, &err);
    if (err) ID3D10Blob_Release(err);
    if (FAILED(hr) || !vsc) { aowl_gfx_fail("VSMain failed to compile"); return 0; }
    hr = ID3D11Device_CreateVertexShader(g_gfx.dev, ID3D10Blob_GetBufferPointer(vsc),
                                         ID3D10Blob_GetBufferSize(vsc), NULL, &g_gfx.vs);
    ID3D10Blob_Release(vsc);
    if (FAILED(hr)) { aowl_gfx_fail("CreateVertexShader failed"); return 0; }

    if (!aowl_gfx_compile_ps("PSMain",   &g_gfx.psMain))   { aowl_gfx_fail("PSMain compile failed");   return 0; }
    if (!aowl_gfx_compile_ps("PSBright", &g_gfx.psBright)) { aowl_gfx_fail("PSBright compile failed"); return 0; }
    if (!aowl_gfx_compile_ps("PSBlur",   &g_gfx.psBlur))   { aowl_gfx_fail("PSBlur compile failed");   return 0; }

    D3D11_SAMPLER_DESC sd; memset(&sd, 0, sizeof(sd));
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_ALWAYS;
    if (FAILED(ID3D11Device_CreateSamplerState(g_gfx.dev, &sd, &g_gfx.samp))) {
        aowl_gfx_fail("CreateSamplerState failed"); return 0;
    }

    D3D11_BUFFER_DESC bd; memset(&bd, 0, sizeof(bd));
    bd.ByteWidth = sizeof(float) * 36;   /* 9 float4 registers */
    bd.Usage = D3D11_USAGE_DYNAMIC;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    bd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(ID3D11Device_CreateBuffer(g_gfx.dev, &bd, NULL, &g_gfx.cb))) {
        aowl_gfx_fail("CreateBuffer(cb) failed"); return 0;
    }

    /* GPU timestamp queries. Deliberately NOT fatal: a driver that refuses
     * them costs us the measurement, not the feature. gpuMs then stays 0 and
     * the status line says "not measured" rather than inventing a number. */
    {
        D3D11_QUERY_DESC qd; memset(&qd, 0, sizeof(qd));
        qd.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
        ID3D11Device_CreateQuery(g_gfx.dev, &qd, &g_gfx.qDisjoint);
        qd.Query = D3D11_QUERY_TIMESTAMP;
        ID3D11Device_CreateQuery(g_gfx.dev, &qd, &g_gfx.qT0);
        ID3D11Device_CreateQuery(g_gfx.dev, &qd, &g_gfx.qT1);
    }

    D3D11_BLEND_DESC bl; memset(&bl, 0, sizeof(bl));
    bl.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(ID3D11Device_CreateBlendState(g_gfx.dev, &bl, &g_gfx.blendOff))) {
        aowl_gfx_fail("CreateBlendState failed"); return 0;
    }

    D3D11_DEPTH_STENCIL_DESC dd; memset(&dd, 0, sizeof(dd));
    dd.DepthEnable = FALSE; dd.StencilEnable = FALSE;
    if (FAILED(ID3D11Device_CreateDepthStencilState(g_gfx.dev, &dd, &g_gfx.depthOff))) {
        aowl_gfx_fail("CreateDepthStencilState failed"); return 0;
    }

    D3D11_RASTERIZER_DESC rd; memset(&rd, 0, sizeof(rd));
    rd.FillMode = D3D11_FILL_SOLID; rd.CullMode = D3D11_CULL_NONE;
    rd.DepthClipEnable = TRUE;
    if (FAILED(ID3D11Device_CreateRasterizerState(g_gfx.dev, &rd, &g_gfx.rast))) {
        aowl_gfx_fail("CreateRasterizerState failed"); return 0;
    }

    /* 1x1 black for t1 when bloom is off */
    uint32_t black = 0;
    D3D11_TEXTURE2D_DESC td; memset(&td, 0, sizeof(td));
    td.Width = 1; td.Height = 1; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE; td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA srd; memset(&srd, 0, sizeof(srd));
    srd.pSysMem = &black; srd.SysMemPitch = 4;
    ID3D11Texture2D* bt = NULL;
    if (SUCCEEDED(ID3D11Device_CreateTexture2D(g_gfx.dev, &td, &srd, &bt))) {
        ID3D11Device_CreateShaderResourceView(g_gfx.dev, (ID3D11Resource*)bt, NULL, &g_gfx.blackSrv);
        ID3D11Texture2D_Release(bt);
    }
    return 1;
}

/* ---------------------------------------------------------------- targets */
static void aowl_gfx_release_size(void) {
    if (g_gfx.bbRtv)     { ID3D11RenderTargetView_Release(g_gfx.bbRtv); g_gfx.bbRtv = NULL; }
    if (g_gfx.sceneSrv)  { ID3D11ShaderResourceView_Release(g_gfx.sceneSrv); g_gfx.sceneSrv = NULL; }
    if (g_gfx.sceneCopy) { ID3D11Texture2D_Release(g_gfx.sceneCopy); g_gfx.sceneCopy = NULL; }
    if (g_gfx.bloomARtv) { ID3D11RenderTargetView_Release(g_gfx.bloomARtv); g_gfx.bloomARtv = NULL; }
    if (g_gfx.bloomASrv) { ID3D11ShaderResourceView_Release(g_gfx.bloomASrv); g_gfx.bloomASrv = NULL; }
    if (g_gfx.bloomA)    { ID3D11Texture2D_Release(g_gfx.bloomA); g_gfx.bloomA = NULL; }
    if (g_gfx.bloomBRtv) { ID3D11RenderTargetView_Release(g_gfx.bloomBRtv); g_gfx.bloomBRtv = NULL; }
    if (g_gfx.bloomBSrv) { ID3D11ShaderResourceView_Release(g_gfx.bloomBSrv); g_gfx.bloomBSrv = NULL; }
    if (g_gfx.bloomB)    { ID3D11Texture2D_Release(g_gfx.bloomB); g_gfx.bloomB = NULL; }
    g_gfx.bbW = g_gfx.bbH = 0;
}

static int aowl_gfx_make_half_rt(UINT w, UINT h, ID3D11Texture2D** tex,
                                 ID3D11RenderTargetView** rtv,
                                 ID3D11ShaderResourceView** srv) {
    D3D11_TEXTURE2D_DESC td; memset(&td, 0, sizeof(td));
    td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    if (FAILED(ID3D11Device_CreateTexture2D(g_gfx.dev, &td, NULL, tex))) return 0;
    if (FAILED(ID3D11Device_CreateRenderTargetView(g_gfx.dev, (ID3D11Resource*)*tex, NULL, rtv))) return 0;
    if (FAILED(ID3D11Device_CreateShaderResourceView(g_gfx.dev, (ID3D11Resource*)*tex, NULL, srv))) return 0;
    return 1;
}

static int aowl_gfx_make_targets(IDXGISwapChain* sc) {
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(sc, 0, &AOWL_GFX_IID_Tex2D, (void**)&bb))) return 0;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(bb, &td);
    g_gfx.bbW = td.Width; g_gfx.bbH = td.Height; g_gfx.bbFormat = td.Format;

    /* view on the back buffer (NULL desc -> its own format, sRGB-correct) */
    HRESULT hr = ID3D11Device_CreateRenderTargetView(g_gfx.dev, (ID3D11Resource*)bb, NULL, &g_gfx.bbRtv);
    if (FAILED(hr)) { ID3D11Texture2D_Release(bb); return 0; }

    /* sampleable copy of the scene, same format & size for CopyResource */
    D3D11_TEXTURE2D_DESC cd; memset(&cd, 0, sizeof(cd));
    cd.Width = td.Width; cd.Height = td.Height; cd.MipLevels = 1; cd.ArraySize = 1;
    cd.Format = td.Format; cd.SampleDesc = td.SampleDesc; cd.SampleDesc.Count = 1;
    cd.Usage = D3D11_USAGE_DEFAULT;
    cd.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    hr = ID3D11Device_CreateTexture2D(g_gfx.dev, &cd, NULL, &g_gfx.sceneCopy);
    if (FAILED(hr)) { ID3D11Texture2D_Release(bb); return 0; }
    hr = ID3D11Device_CreateShaderResourceView(g_gfx.dev, (ID3D11Resource*)g_gfx.sceneCopy, NULL, &g_gfx.sceneSrv);
    ID3D11Texture2D_Release(bb);
    if (FAILED(hr)) return 0;   /* typeless back buffer: bail, run passthrough */

    UINT hw = td.Width / 2 > 0 ? td.Width / 2 : 1;
    UINT hh = td.Height / 2 > 0 ? td.Height / 2 : 1;
    if (!aowl_gfx_make_half_rt(hw, hh, &g_gfx.bloomA, &g_gfx.bloomARtv, &g_gfx.bloomASrv)) return 0;
    if (!aowl_gfx_make_half_rt(hw, hh, &g_gfx.bloomB, &g_gfx.bloomBRtv, &g_gfx.bloomBSrv)) return 0;
    return 1;
}

/* ---------------------------------------------------------------- state I/O
 * A compact save/restore of just the pipeline state our fullscreen passes
 * touch. Smaller than the overlay's because we do not blend and use no VB. */
typedef struct AowlGfxSaved {
    UINT vpN; D3D11_VIEWPORT vp[D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE];
    ID3D11RenderTargetView* rtvs[D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT];
    ID3D11DepthStencilView* dsv;
    ID3D11ShaderResourceView* srv0; ID3D11ShaderResourceView* srv1;
    ID3D11SamplerState* samp0;
    ID3D11PixelShader* ps; ID3D11VertexShader* vs;
    ID3D11Buffer* psCb;
    ID3D11BlendState* blend; FLOAT bf[4]; UINT mask;
    ID3D11DepthStencilState* depth; UINT sref;
    ID3D11RasterizerState* rast;
    D3D11_PRIMITIVE_TOPOLOGY topo;
    ID3D11InputLayout* layout;
    ID3D11Buffer* vb; UINT vbStride, vbOffset;
} AowlGfxSaved;

static void aowl_gfx_save(ID3D11DeviceContext* c, AowlGfxSaved* s) {
    memset(s, 0, sizeof(*s));
    s->vpN = D3D11_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    ID3D11DeviceContext_RSGetViewports(c, &s->vpN, s->vp);
    ID3D11DeviceContext_OMGetRenderTargets(c, D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT, s->rtvs, &s->dsv);
    ID3D11DeviceContext_PSGetShaderResources(c, 0, 1, &s->srv0);
    ID3D11DeviceContext_PSGetShaderResources(c, 1, 1, &s->srv1);
    ID3D11DeviceContext_PSGetSamplers(c, 0, 1, &s->samp0);
    ID3D11DeviceContext_PSGetShader(c, &s->ps, NULL, NULL);
    ID3D11DeviceContext_VSGetShader(c, &s->vs, NULL, NULL);
    ID3D11DeviceContext_PSGetConstantBuffers(c, 0, 1, &s->psCb);
    ID3D11DeviceContext_OMGetBlendState(c, &s->blend, s->bf, &s->mask);
    ID3D11DeviceContext_OMGetDepthStencilState(c, &s->depth, &s->sref);
    ID3D11DeviceContext_RSGetState(c, &s->rast);
    ID3D11DeviceContext_IAGetPrimitiveTopology(c, &s->topo);
    ID3D11DeviceContext_IAGetInputLayout(c, &s->layout);
    ID3D11DeviceContext_IAGetVertexBuffers(c, 0, 1, &s->vb, &s->vbStride, &s->vbOffset);
}

/* Settle the depth question with a measurement instead of a claim.
 *
 * `aowl_gfx_save` asks OMGetRenderTargets for whatever depth-stencil view is
 * bound at Present. If a real, full-resolution scene depth texture is still
 * bound there and it carries D3D11_BIND_SHADER_RESOURCE, then SSAO / fog /
 * DoF are reachable from this exact hook with NO new hook and no interception
 * of the device context. If the DSV is NULL, or the texture is not
 * SRV-bindable, then it is not reachable this way and the ReShade-style route
 * (intercepting ID3D11Device::CreateTexture2D to add BIND_SHADER_RESOURCE and
 * promote the format to typeless, plus tracking clears) is the only option --
 * a much larger, per-draw-call write into the game's renderer.
 *
 * Recorded ONCE, verbatim, into the status line. Three outcomes, not two:
 * "no DSV bound", "DSV bound but not SRV-bindable", "DSV bound, SRV-bindable".
 * Nothing here binds, reads or modifies the depth buffer -- it only reports a
 * descriptor. */
static void aowl_gfx_probe_depth(ID3D11DepthStencilView* dsv, UINT bbW, UINT bbH) {
    if (g_gfx.depthProbed) return;
    g_gfx.depthProbed = 1;
    if (!dsv) {
        strcpy(g_gfx.depthNote, "depth: NO DSV bound at Present -> not reachable from this hook");
        return;
    }
    ID3D11Resource* res = NULL;
    ID3D11DepthStencilView_GetResource(dsv, &res);
    if (!res) {
        strcpy(g_gfx.depthNote, "depth: DSV bound but GetResource failed -> INCONCLUSIVE");
        return;
    }
    ID3D11Texture2D* tex = NULL;
    static const GUID IID_T2D =
        { 0x6f15aaf2, 0xd208, 0x4e89, { 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };
    if (FAILED(ID3D11Resource_QueryInterface(res, &IID_T2D, (void**)&tex)) || !tex) {
        ID3D11Resource_Release(res);
        strcpy(g_gfx.depthNote, "depth: DSV resource is not a Texture2D -> INCONCLUSIVE");
        return;
    }
    D3D11_TEXTURE2D_DESC td; ID3D11Texture2D_GetDesc(tex, &td);
    _snprintf(g_gfx.depthNote, sizeof(g_gfx.depthNote) - 1,
              "depth: DSV %ux%u fmt=%u bind=0x%X srv=%s fullres=%s",
              (unsigned)td.Width, (unsigned)td.Height, (unsigned)td.Format,
              (unsigned)td.BindFlags,
              (td.BindFlags & D3D11_BIND_SHADER_RESOURCE) ? "YES" : "no",
              (td.Width == bbW && td.Height == bbH) ? "yes" : "no");
    g_gfx.depthNote[sizeof(g_gfx.depthNote) - 1] = 0;
    ID3D11Texture2D_Release(tex);
    ID3D11Resource_Release(res);
}

static int32_t aowl_gfx_depth_note(char* buf, int32_t cap) {
    if (!buf || cap <= 0) return 0;
    const char* s = g_gfx.depthProbed ? g_gfx.depthNote : "depth: not probed yet (no frame graded)";
    int32_t l = (int32_t)strlen(s);
    if (l >= cap) l = cap - 1;
    memcpy(buf, s, (size_t)l); buf[l] = 0;
    return l;
}

static void aowl_gfx_restore(ID3D11DeviceContext* c, AowlGfxSaved* s) {
    ID3D11DeviceContext_RSSetViewports(c, s->vpN, s->vp);
    ID3D11DeviceContext_OMSetRenderTargets(c, D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT, s->rtvs, s->dsv);
    for (UINT i = 0; i < D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT; i++)
        if (s->rtvs[i]) ID3D11RenderTargetView_Release(s->rtvs[i]);
    if (s->dsv) ID3D11DepthStencilView_Release(s->dsv);
    ID3D11DeviceContext_PSSetShaderResources(c, 0, 1, &s->srv0);
    if (s->srv0) ID3D11ShaderResourceView_Release(s->srv0);
    ID3D11DeviceContext_PSSetShaderResources(c, 1, 1, &s->srv1);
    if (s->srv1) ID3D11ShaderResourceView_Release(s->srv1);
    ID3D11DeviceContext_PSSetSamplers(c, 0, 1, &s->samp0);
    if (s->samp0) ID3D11SamplerState_Release(s->samp0);
    ID3D11DeviceContext_PSSetShader(c, s->ps, NULL, 0);
    if (s->ps) ID3D11PixelShader_Release(s->ps);
    ID3D11DeviceContext_VSSetShader(c, s->vs, NULL, 0);
    if (s->vs) ID3D11VertexShader_Release(s->vs);
    ID3D11DeviceContext_PSSetConstantBuffers(c, 0, 1, &s->psCb);
    if (s->psCb) ID3D11Buffer_Release(s->psCb);
    ID3D11DeviceContext_OMSetBlendState(c, s->blend, s->bf, s->mask);
    if (s->blend) ID3D11BlendState_Release(s->blend);
    ID3D11DeviceContext_OMSetDepthStencilState(c, s->depth, s->sref);
    if (s->depth) ID3D11DepthStencilState_Release(s->depth);
    ID3D11DeviceContext_RSSetState(c, s->rast);
    if (s->rast) ID3D11RasterizerState_Release(s->rast);
    ID3D11DeviceContext_IASetPrimitiveTopology(c, s->topo);
    ID3D11DeviceContext_IASetInputLayout(c, s->layout);
    if (s->layout) ID3D11InputLayout_Release(s->layout);
    ID3D11DeviceContext_IASetVertexBuffers(c, 0, 1, &s->vb, &s->vbStride, &s->vbOffset);
    if (s->vb) ID3D11Buffer_Release(s->vb);
}

static void aowl_gfx_upload_cb(const AowlGfxParams* p, float texW, float texH,
                               float gate, float timeSec) {
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(g_gfx.ctx, (ID3D11Resource*)g_gfx.cb, 0,
                                       D3D11_MAP_WRITE_DISCARD, 0, &m))) return;
    float* f = (float*)m.pData;
    f[0]=p->enabled; f[1]=p->exposure; f[2]=p->contrast; f[3]=p->saturation;
    f[4]=p->temperature; f[5]=p->tint; f[6]=p->tonemapper; f[7]=p->tonemapStrength;
    f[8]=p->lift; f[9]=p->gamma; f[10]=p->gain; f[11]=p->shadows;
    f[12]=p->highlights; f[13]=p->sharpness; f[14]=p->vignette; f[15]=p->bloomStrength;
    f[16]=1.0f/texW; f[17]=1.0f/texH; f[18]=p->vignetteRadius; f[19]=p->diag;
    f[20]=gate;          f[21]=timeSec;        f[22]=p->clarity;    f[23]=p->vibrance;
    f[24]=p->shadowDetail;f[25]=p->grain;       f[26]=p->grainSize;  f[27]=p->dither;
    f[28]=p->chroma;      f[29]=p->bloomThreshold; f[30]=texW;       f[31]=texH;
    f[32]=0.0f; f[33]=0.0f; f[34]=0.0f; f[35]=0.0f;
    ID3D11DeviceContext_Unmap(g_gfx.ctx, (ID3D11Resource*)g_gfx.cb, 0);
}

static void aowl_gfx_fullscreen(ID3D11DeviceContext* c, ID3D11PixelShader* ps,
                                ID3D11RenderTargetView* rtv,
                                ID3D11ShaderResourceView* t0,
                                ID3D11ShaderResourceView* t1,
                                UINT w, UINT h) {
    D3D11_VIEWPORT vp; memset(&vp, 0, sizeof(vp));
    vp.Width = (FLOAT)w; vp.Height = (FLOAT)h; vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(c, 1, &vp);
    ID3D11RenderTargetView* rts[1] = { rtv };
    ID3D11DeviceContext_OMSetRenderTargets(c, 1, rts, NULL);
    ID3D11ShaderResourceView* srvs[2] = { t0, t1 ? t1 : g_gfx.blackSrv };
    ID3D11DeviceContext_PSSetShaderResources(c, 0, 2, srvs);
    ID3D11DeviceContext_PSSetSamplers(c, 0, 1, &g_gfx.samp);
    ID3D11DeviceContext_PSSetConstantBuffers(c, 0, 1, &g_gfx.cb);
    ID3D11DeviceContext_VSSetShader(c, g_gfx.vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(c, ps, NULL, 0);
    ID3D11DeviceContext_IASetInputLayout(c, NULL);
    ID3D11DeviceContext_IASetVertexBuffers(c, 0, 0, NULL, NULL, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(c, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    FLOAT bf[4] = {0,0,0,0};
    ID3D11DeviceContext_OMSetBlendState(c, g_gfx.blendOff, bf, 0xffffffff);
    ID3D11DeviceContext_OMSetDepthStencilState(c, g_gfx.depthOff, 0);
    ID3D11DeviceContext_RSSetState(c, g_gfx.rast);
    ID3D11DeviceContext_Draw(c, 3, 0);
    /* unbind SRVs so the next pass can use these textures as RTs */
    ID3D11ShaderResourceView* nulls[2] = { NULL, NULL };
    ID3D11DeviceContext_PSSetShaderResources(c, 0, 2, nulls);
}

/* ---------------------------------------------------------------- device up */
static int aowl_gfx_ensure_device(IDXGISwapChain* sc) {
    if (g_gfx.deviceReady) return 1;
    if (FAILED(IDXGISwapChain_GetDevice(sc, &AOWL_GFX_IID_Tex2D, (void**)&g_gfx.dev))) {
        /* wrong IID -- use the device IID */
    }
    /* proper device query */
    if (!g_gfx.dev) {
        static const GUID IID_Dev =
          { 0xdb6f6ddb, 0xac77, 0x4e88, { 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 } };
        if (FAILED(IDXGISwapChain_GetDevice(sc, &IID_Dev, (void**)&g_gfx.dev))) {
            aowl_gfx_fail("could not get the D3D11 device from the swap chain");
            return 0;
        }
    }
    ID3D11Device_GetImmediateContext(g_gfx.dev, &g_gfx.ctx);
    if (!g_gfx.ctx) { aowl_gfx_fail("no immediate context"); return 0; }

    if (!g_gfx.compile) {
        g_gfx.d3dcompiler = LoadLibraryA("d3dcompiler_47.dll");
        if (!g_gfx.d3dcompiler) g_gfx.d3dcompiler = LoadLibraryA("d3dcompiler_46.dll");
        if (g_gfx.d3dcompiler)
            g_gfx.compile = (AowlGfxD3DCompileFn)(void*)GetProcAddress(g_gfx.d3dcompiler, "D3DCompile");
        if (!g_gfx.compile) { aowl_gfx_fail("d3dcompiler_47.dll / D3DCompile not found"); return 0; }
    }
    if (!aowl_gfx_make_pipeline()) return 0;
    g_gfx.swap = sc;
    g_gfx.deviceReady = 1;
    aowl_gfx_note("device ready; post-process live");
    return 1;
}

/* ---------------------------------------------------------------- the pass */
static void aowl_gfx_render(IDXGISwapChain* sc) {
    if (!aowl_gfx_ensure_device(sc)) return;

    AowlGfxParams p;
    EnterCriticalSection(&g_gfx.cs);
    p = g_gfx.params;
    LeaveCriticalSection(&g_gfx.cs);

    /* Raid-state gate. The effect is on only when enabled AND (raidOnly is off,
     * or the host says we are in a raid). `diag` forces it on regardless, so the
     * red-tint blit test works anywhere. `gateAmount` ramps toward the target a
     * step per frame so the grade fades in/out rather than popping at the menu
     * <-> raid boundary; at 0 the frame is left completely untouched (a true
     * pass-through, and the cheapest path). */
    int wantOn = (p.enabled >= 0.5f) &&
                 (p.diag >= 0.5f || p.raidOnly < 0.5f || g_gfx.inRaid);
    float target = wantOn ? 1.0f : 0.0f;
    if (g_gfx.gateAmount < target) {
        g_gfx.gateAmount += 0.08f;
        if (g_gfx.gateAmount > target) g_gfx.gateAmount = target;
    } else if (g_gfx.gateAmount > target) {
        g_gfx.gateAmount -= 0.08f;
        if (g_gfx.gateAmount < target) g_gfx.gateAmount = target;
    }
    if (g_gfx.gateAmount <= 0.001f) return;   /* fully passed through */
    float gate = g_gfx.gateAmount;

    /* (re)build size-dependent targets */
    ID3D11Texture2D* bb = NULL;
    if (FAILED(IDXGISwapChain_GetBuffer(sc, 0, &AOWL_GFX_IID_Tex2D, (void**)&bb))) return;
    D3D11_TEXTURE2D_DESC td; ID3D11Texture2D_GetDesc(bb, &td);
    if (td.Width != g_gfx.bbW || td.Height != g_gfx.bbH || !g_gfx.bbRtv) {
        aowl_gfx_release_size();
        if (!aowl_gfx_make_targets(sc)) { ID3D11Texture2D_Release(bb); return; }
    }
    ID3D11DeviceContext* c = g_gfx.ctx;

    /* Wall clock in seconds, for the animated grain/dither. Monotonic and
     * wrapped so the float never loses precision in a long session. */
    float tsec;
    {
        LARGE_INTEGER f, t;
        QueryPerformanceFrequency(&f); QueryPerformanceCounter(&t);
        tsec = (float)((double)(t.QuadPart % (f.QuadPart * 3600)) / (double)f.QuadPart);
    }

    AowlGfxSaved saved;
    aowl_gfx_save(c, &saved);
    aowl_gfx_probe_depth(saved.dsv, g_gfx.bbW, g_gfx.bbH);

    /* Collect a previously-issued timing window, non-blocking; only issue a
     * new one when none is in flight. Issuing timestamps every frame is itself
     * a measurable cost, so this samples rather than instruments. */
    int timing = 0;
    if (g_gfx.qDisjoint && g_gfx.qT0 && g_gfx.qT1) {
        if (g_gfx.qInFlight) {
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT dj; UINT64 a = 0, b = 0;
            if (ID3D11DeviceContext_GetData(c, (ID3D11Asynchronous*)g_gfx.qDisjoint,
                    &dj, sizeof(dj), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                ID3D11DeviceContext_GetData(c, (ID3D11Asynchronous*)g_gfx.qT0,
                    &a, sizeof(a), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                ID3D11DeviceContext_GetData(c, (ID3D11Asynchronous*)g_gfx.qT1,
                    &b, sizeof(b), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK) {
                g_gfx.qInFlight = 0;
                if (!dj.Disjoint && dj.Frequency && b > a) {
                    float ms = (float)((double)(b - a) * 1000.0 / (double)dj.Frequency);
                    /* exponential average -- one frame is not a number */
                    g_gfx.gpuMs = g_gfx.gpuSamples ? (g_gfx.gpuMs * 0.9f + ms * 0.1f) : ms;
                    g_gfx.gpuSamples++;
                }
            }
        } else {
            ID3D11DeviceContext_Begin(c, (ID3D11Asynchronous*)g_gfx.qDisjoint);
            ID3D11DeviceContext_End(c, (ID3D11Asynchronous*)g_gfx.qT0);
            timing = 1;
        }
    }

    /* snapshot the finished frame into the sampleable copy */
    ID3D11DeviceContext_CopyResource(c, (ID3D11Resource*)g_gfx.sceneCopy, (ID3D11Resource*)bb);
    ID3D11Texture2D_Release(bb);

    int doBloom = (p.bloom > 0.5f && p.bloomStrength > 0.001f);
    if (doBloom) {
        UINT hw = g_gfx.bbW / 2 > 0 ? g_gfx.bbW / 2 : 1;
        UINT hh = g_gfx.bbH / 2 > 0 ? g_gfx.bbH / 2 : 1;
        /* bright pass: sceneCopy -> bloomA (texel size = full res source) */
        aowl_gfx_upload_cb(&p, (float)g_gfx.bbW, (float)g_gfx.bbH, gate, tsec);
        aowl_gfx_fullscreen(c, g_gfx.psBright, g_gfx.bloomARtv, g_gfx.sceneSrv, NULL, hw, hh);
        /* blur H: bloomA -> bloomB (texel = half res, x only) */
        AowlGfxParams hp = p; /* reuse cb, but blur reads _TexelSize as direction */
        aowl_gfx_upload_cb(&hp, (float)hw, 1.0e30f, gate, tsec);  /* 1/x = 1/hw, 1/y ~ 0 => horizontal */
        aowl_gfx_fullscreen(c, g_gfx.psBlur, g_gfx.bloomBRtv, g_gfx.bloomASrv, NULL, hw, hh);
        /* blur V: bloomB -> bloomA (y only) */
        aowl_gfx_upload_cb(&hp, 1.0e30f, (float)hh, gate, tsec);
        aowl_gfx_fullscreen(c, g_gfx.psBlur, g_gfx.bloomARtv, g_gfx.bloomBSrv, NULL, hw, hh);
    }

    /* main pass: sceneCopy (+ bloomA) -> back buffer */
    aowl_gfx_upload_cb(&p, (float)g_gfx.bbW, (float)g_gfx.bbH, gate, tsec);
    aowl_gfx_fullscreen(c, g_gfx.psMain, g_gfx.bbRtv, g_gfx.sceneSrv,
                        doBloom ? g_gfx.bloomASrv : g_gfx.blackSrv, g_gfx.bbW, g_gfx.bbH);

    if (timing) {
        ID3D11DeviceContext_End(c, (ID3D11Asynchronous*)g_gfx.qT1);
        ID3D11DeviceContext_End(c, (ID3D11Asynchronous*)g_gfx.qDisjoint);
        g_gfx.qInFlight = 1;
    }

    aowl_gfx_restore(c, &saved);
    g_gfx.frames++;
}

/* ---------------------------------------------------------------- detours */
typedef HRESULT (WINAPI *AowlGfxPresentFn)(IDXGISwapChain*, UINT, UINT);
typedef HRESULT (WINAPI *AowlGfxResizeFn)(IDXGISwapChain*, UINT, UINT, UINT, DXGI_FORMAT, UINT);

static HRESULT WINAPI aowl_gfx_present(IDXGISwapChain* sc, UINT sync, UINT flags) {
    AowlGfxPresentFn orig = (AowlGfxPresentFn)g_gfx.presentOrig;
    if (g_gfx.broken || (flags & DXGI_PRESENT_TEST))
        return orig(sc, sync, flags);
    if (InterlockedCompareExchange(&g_gfx.inPresent, 1, 0) != 0)
        return orig(sc, sync, flags);   /* nested Present: do nothing extra */
    /* guard the whole render in a soft way: a driver error must not throw */
    aowl_gfx_render(sc);
    InterlockedExchange(&g_gfx.inPresent, 0);
    return orig(sc, sync, flags);
}

static HRESULT WINAPI aowl_gfx_resize(IDXGISwapChain* sc, UINT count, UINT w, UINT h,
                                      DXGI_FORMAT fmt, UINT flags) {
    AowlGfxResizeFn orig = (AowlGfxResizeFn)g_gfx.resizeOrig;
    /* our views pin the back buffer; drop them before the game resizes it */
    aowl_gfx_release_size();
    return orig(sc, count, w, h, fmt, flags);
}

/* ---------------------------------------------------------------- vtable */
typedef HRESULT (WINAPI *AowlGfxCreateFn)(IDXGIAdapter*, D3D_DRIVER_TYPE, HMODULE, UINT,
                                          const D3D_FEATURE_LEVEL*, UINT, UINT,
                                          const DXGI_SWAP_CHAIN_DESC*, IDXGISwapChain**,
                                          ID3D11Device**, D3D_FEATURE_LEVEL*, ID3D11DeviceContext**);
#define AOWL_GFX_SLOT_PRESENT 8
#define AOWL_GFX_SLOT_RESIZE  13

static int aowl_gfx_capture_vtable(void** outPresent, void** outResize) {
    HMODULE d3d11 = LoadLibraryA("d3d11.dll");
    if (!d3d11) { aowl_gfx_fail("d3d11.dll is not loaded"); return 0; }
    AowlGfxCreateFn create =
        (AowlGfxCreateFn)(void*)GetProcAddress(d3d11, "D3D11CreateDeviceAndSwapChain");
    if (!create) { aowl_gfx_fail("D3D11CreateDeviceAndSwapChain not found"); return 0; }

    WNDCLASSEXW wc; memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"aowlspt_gfx_probe";
    RegisterClassExW(&wc);
    HWND hw = CreateWindowExW(0, L"aowlspt_gfx_probe", L"", WS_OVERLAPPEDWINDOW,
                              0, 0, 1, 1, NULL, NULL, wc.hInstance, NULL);
    if (!hw) { UnregisterClassW(L"aowlspt_gfx_probe", wc.hInstance);
               aowl_gfx_fail("could not create the probe window"); return 0; }

    DXGI_SWAP_CHAIN_DESC sd; memset(&sd, 0, sizeof(sd));
    sd.BufferCount = 1; sd.BufferDesc.Width = 1; sd.BufferDesc.Height = 1;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hw; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    IDXGISwapChain* sc = NULL; ID3D11Device* dev = NULL; ID3D11DeviceContext* ctx = NULL;
    D3D_FEATURE_LEVEL got;
    HRESULT hr = create(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                        D3D11_SDK_VERSION, &sd, &sc, &dev, &got, &ctx);
    if (FAILED(hr))
        hr = create(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, NULL, 0,
                    D3D11_SDK_VERSION, &sd, &sc, &dev, &got, &ctx);
    int ok = 0;
    if (SUCCEEDED(hr) && sc) {
        void** vt = *(void***)sc;
        *outPresent = vt[AOWL_GFX_SLOT_PRESENT];
        *outResize  = vt[AOWL_GFX_SLOT_RESIZE];
        ok = 1;
    } else aowl_gfx_fail("could not create the probe swap chain");
    if (ctx) ID3D11DeviceContext_Release(ctx);
    if (dev) ID3D11Device_Release(dev);
    if (sc)  IDXGISwapChain_Release(sc);
    DestroyWindow(hw);
    UnregisterClassW(L"aowlspt_gfx_probe", wc.hInstance);
    return ok;
}

/* ---------------------------------------------------------------- driven mode
 * When the overlay already owns the Present hook (the detour engine refuses a
 * second hook on the same dxgi function), the post-process runs from the
 * overlay's pre-present callback instead of its own detour. These are the entry
 * points for that path: `aowl_gfx_grade` does one frame of grading given the
 * live swap chain, `aowl_gfx_release_size_extern` drops the back-buffer refs
 * before a resize, and the two `*_ptr` accessors hand the host a plain function
 * pointer to register with the overlay (a `void*` crosses the nimony host
 * cleanly; a cast to a proc type would not). */
static void aowl_gfx_grade(IDXGISwapChain* sc) {
    if (!g_gfx.started || g_gfx.broken || !sc) return;
    if (InterlockedCompareExchange(&g_gfx.inPresent, 1, 0) != 0) return;
    aowl_gfx_render(sc);
    InterlockedExchange(&g_gfx.inPresent, 0);
}
static void aowl_gfx_release_size_extern(IDXGISwapChain* sc) {
    (void)sc;
    aowl_gfx_release_size();
}
static void* aowl_gfx_grade_ptr(void)   { return (void*)aowl_gfx_grade; }
static void* aowl_gfx_release_ptr(void)  { return (void*)aowl_gfx_release_size_extern; }

/* Start WITHOUT installing a hook. The overlay drives grading via the pointers
 * above. Only the state + params are set up; the device comes up lazily on the
 * first `aowl_gfx_grade`. */
static int32_t aowl_gfx_start_driven(void) {
    if (InterlockedCompareExchange(&g_gfx.started, 1, 0) != 0) return 1;
    InterlockedExchange(&g_gfx.broken, 0);
    aowl_gfx_ensure_init();   /* cs + defaults, once; a grade the mod already
                               * pushed before this call is preserved. */
    aowl_gfx_note("driven by the overlay Present hook; waiting for the first frame");
    return 1;
}

/* ---------------------------------------------------------------- lifecycle
 * Must NOT be called from DllMain (device + window under the loader lock). The
 * host boot thread is the right caller. Used only when NO overlay owns Present;
 * otherwise the host uses aowl_gfx_start_driven + the overlay callbacks. */
static int32_t aowl_gfx_start(void) {
    if (InterlockedCompareExchange(&g_gfx.started, 1, 0) != 0) return 1;
    InterlockedExchange(&g_gfx.broken, 0);
    aowl_gfx_ensure_init();   /* cs + defaults, once (see aowl_gfx_ensure_init) */
    aowl_gfx_note("starting");

    void* present = NULL; void* resize = NULL;
    if (!aowl_gfx_capture_vtable(&present, &resize)) return 0;

    g_gfx.presentHook = aowl_hook_new();
    g_gfx.resizeHook  = aowl_hook_new();
    if (!g_gfx.presentHook || !g_gfx.resizeHook) { aowl_gfx_fail("out of memory"); return 0; }

    if (aowl_hook_install(g_gfx.presentHook, present, (void*)aowl_gfx_present) != 0) {
        aowl_gfx_fail("could not hook Present"); return 0;
    }
    g_gfx.presentOrig = aowl_hook_trampoline(g_gfx.presentHook);

    if (aowl_hook_install(g_gfx.resizeHook, resize, (void*)aowl_gfx_resize) != 0) {
        aowl_hook_remove(g_gfx.presentHook);
        aowl_gfx_fail("could not hook ResizeBuffers"); return 0;
    }
    g_gfx.resizeOrig = aowl_hook_trampoline(g_gfx.resizeHook);

    aowl_gfx_note("hooked; waiting for the first frame");
    return 1;
}

static void aowl_gfx_stop(void) {
    if (!g_gfx.started) return;
    InterlockedExchange(&g_gfx.broken, 1);
    Sleep(120);   /* let the render thread leave the detour */
    if (g_gfx.presentHook) { aowl_hook_remove(g_gfx.presentHook); aowl_hook_free(g_gfx.presentHook); g_gfx.presentHook = NULL; }
    if (g_gfx.resizeHook)  { aowl_hook_remove(g_gfx.resizeHook);  aowl_hook_free(g_gfx.resizeHook);  g_gfx.resizeHook = NULL; }
    aowl_gfx_release_size();
    if (g_gfx.blackSrv) { ID3D11ShaderResourceView_Release(g_gfx.blackSrv); g_gfx.blackSrv = NULL; }
    if (g_gfx.samp)     { ID3D11SamplerState_Release(g_gfx.samp); g_gfx.samp = NULL; }
    if (g_gfx.cb)       { ID3D11Buffer_Release(g_gfx.cb); g_gfx.cb = NULL; }
    if (g_gfx.qDisjoint){ ID3D11Query_Release(g_gfx.qDisjoint); g_gfx.qDisjoint = NULL; }
    if (g_gfx.qT0)      { ID3D11Query_Release(g_gfx.qT0); g_gfx.qT0 = NULL; }
    if (g_gfx.qT1)      { ID3D11Query_Release(g_gfx.qT1); g_gfx.qT1 = NULL; }
    g_gfx.qInFlight = 0; g_gfx.gpuSamples = 0; g_gfx.gpuMs = 0.0f;
    g_gfx.depthProbed = 0; g_gfx.depthNote[0] = 0;
    if (g_gfx.blendOff) { ID3D11BlendState_Release(g_gfx.blendOff); g_gfx.blendOff = NULL; }
    if (g_gfx.depthOff) { ID3D11DepthStencilState_Release(g_gfx.depthOff); g_gfx.depthOff = NULL; }
    if (g_gfx.rast)     { ID3D11RasterizerState_Release(g_gfx.rast); g_gfx.rast = NULL; }
    if (g_gfx.psMain)   { ID3D11PixelShader_Release(g_gfx.psMain); g_gfx.psMain = NULL; }
    if (g_gfx.psBright) { ID3D11PixelShader_Release(g_gfx.psBright); g_gfx.psBright = NULL; }
    if (g_gfx.psBlur)   { ID3D11PixelShader_Release(g_gfx.psBlur); g_gfx.psBlur = NULL; }
    if (g_gfx.vs)       { ID3D11VertexShader_Release(g_gfx.vs); g_gfx.vs = NULL; }
    if (g_gfx.ctx)      { ID3D11DeviceContext_Release(g_gfx.ctx); g_gfx.ctx = NULL; }
    if (g_gfx.dev)      { ID3D11Device_Release(g_gfx.dev); g_gfx.dev = NULL; }
    g_gfx.deviceReady = 0;
    DeleteCriticalSection(&g_gfx.cs);
    /* Allow a later start to bring the cs back up (InitOnce is one-shot). */
    InitOnceInitialize(&g_gfx_once);
    InterlockedExchange(&g_gfx.started, 0);
}

#endif /* AOWLSPT_GRAPHICS_H */
