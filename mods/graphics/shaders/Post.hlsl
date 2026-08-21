// ===========================================================================
// aowl.graphics -- full-frame post-process stack (D3D11, screen-space)
// ===========================================================================
//
// This is the HLSL the native host module (abi/aowlspt_graphics.h) runs over
// the game's back buffer inside a Present hook. It is compiled at runtime with
// D3DCompile (d3dcompiler_47.dll) against the game's own D3D11 device, so it
// never touches Unity, IL2CPP, an AssetBundle or a managed Material. The same
// text is embedded as a fallback string in the header; this file is the source
// of truth and the thing a user edits.
//
// IMPORTANT — what a screen-space pass can and cannot do
// ------------------------------------------------------
// By the time DXGI Present is called the game has already tonemapped and
// written an 8-bit sRGB (or R10G10B10A2) back buffer. We do NOT see the linear
// HDR scene the way the original BepInEx OnRenderImage pass did. So AgX here is
// a *look* transform applied on top of the shipped image (exposure push into a
// filmic contrast/hue-preserving curve), not a literal replacement of BSG's
// tonemapper. That is the honest capability of the ReShade-style path, and it
// still gets most of the visual win: neutral highlights, controlled contrast,
// clean color grading and sharpening. Depth-dependent effects (SSAO) are NOT
// here — the depth buffer is bound separately by the engine and is not the
// back buffer; that work is parked for the in-engine (bridge) path.
//
// Pipeline order (perceptual, matches a real grading chain):
//   linearize -> exposure -> white balance -> bloom composite ->
//   tonemap look (AgX / ACES / none) -> lift/gamma/gain -> contrast ->
//   saturation -> vignette -> CAS sharpen -> back to sRGB
// ===========================================================================

// --- constant buffer: one float4 register per group of params ---------------
cbuffer Params : register(b0)
{
    // c0
    float _Enabled;      // master; 0 => straight passthrough
    float _Exposure;     // EV bias, applied in linear
    float _Contrast;     // 1 = neutral (pivots around 0.18)
    float _Saturation;   // 1 = neutral, 0 = grey, >1 vivid
    // c1
    float _Temperature;  // -1..1 warm/cool
    float _Tint;         // -1..1 green/magenta
    float _Tonemapper;   // 0 = none, 1 = AgX, 2 = ACES
    float _TonemapStrength; // 0..1 blend of the look
    // c2
    float _Lift;         // shadows offset (-)
    float _Gamma;        // midtone power
    float _Gain;         // highlight scale
    float _Shadows;      // extra shadow lift (matches original)
    // c3
    float _Highlights;   // pre-tonemap highlight scale (matches original)
    float _Sharpness;    // CAS amount 0..1
    float _Vignette;     // 0..1 strength
    float _BloomStrength;// 0..2 composite amount
    // c4
    float2 _TexelSize;   // 1/width, 1/height
    float _VignetteRadius; // 0..1.5
    float _Diag;         // 1 => red tint diagnostic (confirms the blit lands)
    // c5
    float _GateAmount;   // 0..1 raid-state fade: 0 = pass-through, 1 = full grade
    float3 _pad5;
}

Texture2D    _Source : register(t0); // the game back buffer (LDR sRGB)
Texture2D    _Bloom  : register(t1); // pre-blurred bright pass (or black)
SamplerState _Samp   : register(s0); // linear clamp

// --- fullscreen triangle ----------------------------------------------------
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

VSOut VSMain(uint id : SV_VertexID)
{
    VSOut o;
    o.uv  = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// --- color space helpers ----------------------------------------------------
float3 SRGBToLinear(float3 c)
{
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
float3 LinearToSRGB(float3 c)
{
    c = saturate(c);
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}
float Luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// ---------------------------------------------------------------------------
// AgX (Troy Sobotka, 2022) — the ported original, in HLSL.
// Matrices identical to Shaders/AgXTonemap.shader. Operates on linear color.
// ---------------------------------------------------------------------------
static const float3x3 AgX_in = float3x3(
    0.842479062253094,  0.0784335999999992, 0.0792237451477643,
    0.0423282422610123, 0.878468636469772,  0.0791661274605434,
    0.0423756549057051, 0.0784336,           0.879142973793104);
static const float3x3 AgX_out = float3x3(
     1.19687900512017,   -0.0980208811401368, -0.0990297440797205,
    -0.0528968517574562,  1.15190312990417,   -0.0989611768448433,
    -0.0529716355144438, -0.0980434501171241,  1.15107367264116);

float3 AgXDefaultContrast(float3 x)
{
    // 6th-order polynomial fit of the AgX sigmoid (Benjamin Wrensch / Sobotka).
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return  15.5     * x4 * x2
          - 40.14    * x4 * x
          + 31.96    * x4
          - 6.868    * x2 * x
          + 0.4298   * x2
          + 0.1191   * x
          - 0.00232;
}

float3 TonemapAgX(float3 color)
{
    const float minEv = -12.47393;
    const float maxEv =   4.026069;
    color = mul(AgX_in, color);
    color = clamp(log2(max(color, 1e-10)), minEv, maxEv);
    color = (color - minEv) / (maxEv - minEv);
    color = AgXDefaultContrast(color);
    color = mul(AgX_out, color);
    return saturate(color);
}

// ---------------------------------------------------------------------------
// ACES (Narkowicz fit) — the optional alternate.
// ---------------------------------------------------------------------------
float3 TonemapACES(float3 x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// --- white balance (simple channel gain, cheap and controllable) ------------
float3 WhiteBalance(float3 c, float temp, float tint)
{
    // temp: warm (+) boosts R, cuts B. tint: (+) toward magenta.
    float3 g = float3(1.0 + temp * 0.20 + tint * 0.05,
                      1.0            - tint * 0.10,
                      1.0 - temp * 0.20 + tint * 0.05);
    return c * g;
}

// --- lift / gamma / gain (ASC-CDL-ish) --------------------------------------
float3 LiftGammaGain(float3 c, float lift, float gammaP, float gain)
{
    c = c * (gain) + lift;                  // gain scales, lift offsets
    c = max(c, 0.0);
    c = pow(c, max(1.0 / max(gammaP, 1e-3), 1e-3)); // midtone power
    return c;
}

// --- CAS-style sharpening (AMD FidelityFX contrast-adaptive, compact) --------
float3 SharpenCAS(float2 uv, float3 center, float amount)
{
    if (amount <= 0.0001) return center;
    float2 t = _TexelSize;
    float3 a = _Source.Sample(_Samp, uv + float2(0, -t.y)).rgb;
    float3 b = _Source.Sample(_Samp, uv + float2(-t.x, 0)).rgb;
    float3 d = _Source.Sample(_Samp, uv + float2( t.x, 0)).rgb;
    float3 e = _Source.Sample(_Samp, uv + float2(0,  t.y)).rgb;
    // work on luma-weighted min/max of the cross
    float3 mn = min(center, min(min(a, b), min(d, e)));
    float3 mx = max(center, max(max(a, b), max(d, e)));
    float3 amp = saturate(min(mn, 1.0 - mx) / max(mx, 1e-4));
    amp = sqrt(amp);
    float w = -amp * (amount * 0.2 + 0.05); // peak sharpening weight
    float3 sum = (a + b + d + e) * w + center;
    float3 norm = center * (1.0) + (a + b + d + e) * w;
    float rcp = 1.0 / (1.0 + 4.0 * w);
    return saturate((center + (a + b + d + e) * w) * rcp);
}

// ===========================================================================
float4 PSMain(VSOut i) : SV_Target
{
    float3 src = _Source.Sample(_Samp, i.uv).rgb;

    if (_Enabled < 0.5)
        return float4(src, 1.0);
    if (_Diag > 0.5)
        return float4(lerp(src, float3(1, 0, 0), 0.5), 1.0); // blit-lands proof

    // 1. sharpen in display space first (CAS wants perceptual neighbours)
    float3 c = SharpenCAS(i.uv, src, _Sharpness);

    // 2. to linear
    c = SRGBToLinear(c);

    // 3. exposure + highlight roll-off (pre-tonemap, matches original)
    c *= exp2(_Exposure);
    // push highlights into the shoulder like the original _Highlights did
    float hl = Luma(c);
    c *= lerp(1.0, 1.0 / max(_Highlights, 0.01), saturate(hl - 0.5) * (1.0 - 1.0 / max(_Highlights, 1.0)));
    // additive shadow lift
    c += _Shadows;

    // 4. white balance
    c = WhiteBalance(c, _Temperature, _Tint);

    // 5. bloom composite (additive, energy from the bright pass)
    float3 bloom = _Bloom.Sample(_Samp, i.uv).rgb;
    c += bloom * _BloomStrength;

    // 6. tonemap look
    float3 mapped = c;
    if (_Tonemapper > 1.5)      mapped = TonemapACES(c);
    else if (_Tonemapper > 0.5) mapped = TonemapAgX(c);
    c = lerp(c, mapped, saturate(_TonemapStrength));
    c = saturate(c);

    // 7. lift / gamma / gain
    c = LiftGammaGain(c, _Lift, _Gamma, _Gain);

    // 8. contrast around 0.18 mid-grey (in linear)
    c = (c - 0.18) * _Contrast + 0.18;
    c = max(c, 0.0);

    // 9. saturation
    float l = Luma(c);
    c = lerp(l.xxx, c, _Saturation);

    // 10. vignette (multiplicative, smooth)
    float2 d = i.uv - 0.5;
    float vig = 1.0 - _Vignette * smoothstep(_VignetteRadius * 0.5, _VignetteRadius, length(d) * 1.4142);
    c *= saturate(vig);

    // 11. back to display, blended by the raid-state gate (0 = untouched frame,
    //     1 = full grade; ramped on the CPU so menu<->raid fades, never pops)
    return float4(lerp(src, LinearToSRGB(c), _GateAmount), 1.0);
}

// ===========================================================================
// Bloom bright-pass + separable blur. Run at half resolution into a scratch
// target before the main pass. Direction is passed in _TexelSize (one axis 0).
// ===========================================================================
float4 PSBloomPrefilter(VSOut i) : SV_Target
{
    float3 c = SRGBToLinear(_Source.Sample(_Samp, i.uv).rgb);
    float l = Luma(c);
    float knee = 0.7;                 // threshold
    float soft = smoothstep(knee, knee + 0.35, l);
    return float4(c * soft, 1.0);
}

float4 PSBlur(VSOut i) : SV_Target
{
    // 9-tap Gaussian along _TexelSize (the caller zeroes the other axis).
    float2 dir = _TexelSize;
    float3 sum = _Source.Sample(_Samp, i.uv).rgb * 0.227027;
    float2 o1 = dir * 1.3846153846;
    float2 o2 = dir * 3.2307692308;
    sum += _Source.Sample(_Samp, i.uv + o1).rgb * 0.3162162162;
    sum += _Source.Sample(_Samp, i.uv - o1).rgb * 0.3162162162;
    sum += _Source.Sample(_Samp, i.uv + o2).rgb * 0.0702702703;
    sum += _Source.Sample(_Samp, i.uv - o2).rgb * 0.0702702703;
    return float4(sum, 1.0);
}
