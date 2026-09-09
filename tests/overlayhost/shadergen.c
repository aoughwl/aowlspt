/* shadergen.c -- compiles the overlay's two shaders at BUILD time and prints
 * their DXBC bytecode as C arrays.
 *
 * The alternative is D3DCompile() at runtime, which means the game process
 * must find and load d3dcompiler_47.dll. Unity usually has it loaded already,
 * so it would usually work -- "usually" being the problem. Compiling here
 * turns a runtime dependency and a possible several-millisecond stall inside
 * Present into two static arrays.
 *
 * vs_4_0/ps_4_0 rather than 5_0: nothing here needs SM5, and 4_0 also runs on
 * a feature level 10 device, which is what a D3D11 fallback path can hand us.
 *
 * Run:  gcc -O2 shadergen.c -o shadergen.exe -ld3dcompiler
 *       ./shadergen.exe > shaders.inc
 */
#define COBJMACROS
#include <windows.h>
#include <d3dcompiler.h>
#include <stdio.h>

static const char* kVS =
"cbuffer Cb : register(b0) { float4 scale; };\n"
"struct VIn { float2 pos : POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };\n"
"struct VOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };\n"
"VOut main(VIn i) {\n"
"  VOut o;\n"
/* Pixel coordinates in, clip space out. scale = (2/w, -2/h, -1, +1): y is
 * flipped because pixel y grows downward and clip y grows upward. */
"  o.pos = float4(i.pos.x * scale.x + scale.z, i.pos.y * scale.y + scale.w, 0.0, 1.0);\n"
"  o.uv = i.uv;\n"
"  o.col = i.col;\n"
"  return o;\n"
"}\n";

static const char* kPS =
"Texture2D tex : register(t0);\n"
"SamplerState smp : register(s0);\n"
"struct VOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };\n"
"float4 main(VOut i) : SV_Target {\n"
/* One shader for both solid quads and glyphs. The atlas holds a fully opaque
 * texel that solid quads point at, so coverage is always a texture read and
 * there is no branch and no second pipeline state. */
"  float a = tex.Sample(smp, i.uv).r;\n"
"  return float4(i.col.rgb, i.col.a * a);\n"
"}\n";

/* The SECOND pixel shader, for AOWL_REGION_CMD_QUAD.
 *
 * `kPS` above samples `.r` ONLY, because the font atlas is R8_UNORM coverage
 * and a solid quad points at an opaque texel in it. Map artwork is colour, so
 * that shader cannot draw it -- it would discard the tile's RGB entirely and
 * paint a flat tint. Hence a second one, rather than a branch: two pipeline
 * states cost one extra PSSetShader per textured batch, and a dynamic branch
 * in the pixel shader costs it on every pixel of every glyph.
 *
 * `col` is a MULTIPLICATIVE tint here, not a colour: 0xFFFFFFFF draws the tile
 * untouched, and the alpha byte is the quad's opacity. That is the contract
 * `aowl_region_quad` documents. */
static const char* kPSTex =
"Texture2D tex : register(t0);\n"
"SamplerState smp : register(s0);\n"
"struct VOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 col : COLOR0; };\n"
"float4 main(VOut i) : SV_Target {\n"
"  float4 t = tex.Sample(smp, i.uv);\n"
"  return t * i.col;\n"
"}\n";

static int emit(const char* src, const char* profile, const char* name) {
    ID3DBlob* code = NULL;
    ID3DBlob* errs = NULL;
    HRESULT hr = D3DCompile(src, strlen(src), name, NULL, NULL, "main", profile,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errs);
    if (FAILED(hr)) {
        fprintf(stderr, "%s: 0x%08lX %s\n", name, (unsigned long)hr,
                errs ? (const char*)ID3D10Blob_GetBufferPointer(errs) : "");
        return 1;
    }
    const unsigned char* p = (const unsigned char*)ID3D10Blob_GetBufferPointer(code);
    size_t n = ID3D10Blob_GetBufferSize(code);
    printf("static const uint8_t %s[%u] = {\n ", name, (unsigned)n);
    for (size_t i = 0; i < n; i++)
        printf(" 0x%02X,%s", p[i], (i % 12 == 11) ? "\n " : "");
    printf("\n};\n\n");
    return 0;
}

int main(void) {
    if (emit(kVS, "vs_4_0", "aowl_ov_vs")) return 1;
    if (emit(kPS, "ps_4_0", "aowl_ov_ps")) return 1;
    if (emit(kPSTex, "ps_4_0", "aowl_ov_ps_tex")) return 1;
    return 0;
}
