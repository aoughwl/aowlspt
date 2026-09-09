/* scene_selftest.c -- OFFLINE proof of the pure logic in abi/aowlspt_scene.h.
 *
 * Runs with NO live client: it exercises the sharedness verdict, the liveness
 * predicate, the Vector2 RAX decode, the float reinterpret round-trip, the
 * guarded field read/write against a local buffer, and confirms that
 * aowl_scene_fn declines (returns NULL) rather than faulting when
 * GameAssembly.dll is absent -- which is exactly the "wrong build" behaviour.
 *
 * Build+run (PowerShell):
 *   gcc -I abi -o tests/scene/scene_selftest.exe tests/scene/scene_selftest.c
 *   tests/scene/scene_selftest.exe
 * Exit 0 = every assertion held; non-zero = the failing check is named.
 */
#include <stdio.h>
#include <string.h>
#include "aowlspt_scene.h"

static int fails = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s\n", msg); fails++; } \
    else         { printf("PASS: %s\n", msg); } } while (0)

int main(void) {
    /* --- sharedness verdict (fact #57) --- */
    CHECK(aowl_scene_share_verdict(1) == AOWL_SCENE_DETOUR_OK,
          "owners==1 -> DETOUR_OK");
    CHECK(aowl_scene_share_verdict(2) == AOWL_SCENE_CALL_ONLY,
          "owners==2 -> CALL_ONLY");
    CHECK(aowl_scene_share_verdict(6438) == AOWL_SCENE_CALL_ONLY,
          "owners==6438 (the stub) -> CALL_ONLY (never detour)");
    CHECK(aowl_scene_share_verdict(0) == AOWL_SCENE_REFUSE,
          "owners==0 (unknown) -> REFUSE");
    CHECK(aowl_scene_share_verdict(-1) == AOWL_SCENE_REFUSE,
          "owners<0 -> REFUSE");

    /* --- liveness predicate (fact #182/#184) --- */
    CHECK(aowl_scene_cachedptr_alive(0) == 0, "cachedPtr==0 -> dead");
    CHECK(aowl_scene_cachedptr_alive(0x7ff000000000ULL) == 1,
          "cachedPtr!=0 -> alive");

    /* liveness on a real wrapper-shaped buffer: bytes at +0x10 decide. */
    {
        unsigned char wrapper[64];
        memset(wrapper, 0, sizeof(wrapper));
        CHECK(aowl_scene_alive(wrapper) == 0,
              "wrapper with m_CachedPtr(+0x10)==0 -> dead");
        *(uint64_t*)(wrapper + AOWL_SCENE_CACHEDPTR_OFF) = 0xdeadbeefULL;
        CHECK(aowl_scene_alive(wrapper) == 1,
              "wrapper with m_CachedPtr(+0x10)!=0 -> alive");
        CHECK(aowl_scene_alive(NULL) == 0, "alive(NULL) -> dead, no fault");
    }

    /* --- Vector2 RAX decode: x in low 32, y in high 32 --- */
    {
        float x = 1.5f, y = -2.25f;
        uint32_t xb, yb; uint64_t packed;
        memcpy(&xb, &x, 4); memcpy(&yb, &y, 4);
        packed = ((uint64_t)yb << 32) | (uint64_t)xb;
        CHECK(aowl_scene_vec2_x(packed) == 1.5, "vec2 low half decodes to x");
        CHECK(aowl_scene_vec2_y(packed) == -2.25, "vec2 high half decodes to y");
    }

    /* --- float reinterpret round-trip --- */
    {
        float f = 3.14159f; double d = 2.718281828;
        CHECK(aowl_scene_bits_f32(aowl_scene_f32_bits(f)) == f,
              "f32 bits round-trip");
        CHECK(aowl_scene_bits_f64(aowl_scene_f64_bits(d)) == d,
              "f64 bits round-trip");
    }

    /* --- guarded field read/write against a local buffer --- */
    {
        unsigned char buf[32];
        int32_t ok = 0;
        uint64_t v;
        memset(buf, 0, sizeof(buf));
        CHECK(aowl_scene_field_readable(buf, 0, 8) == 1,
              "local buffer is field-readable");
        CHECK(aowl_scene_field_readable(NULL, 0, 4) == 0,
              "NULL is not field-readable");
        CHECK(aowl_scene_field_readable(buf, 0, 3) == 1,
              "field_readable is width-agnostic (3 readable bytes -> 1)");
        CHECK(aowl_scene_field_readable(buf, 0, 9) == 0,
              "field_readable refuses n>8");

        CHECK(aowl_scene_write_bits(buf, 4, 4, 0x11223344u) == 1,
              "write u32 into RW buffer succeeds");
        v = aowl_scene_read_bits(buf, 4, 4, &ok);
        CHECK(ok == 1 && v == 0x11223344u, "read back the u32 just written");

        CHECK(aowl_scene_write_bits(buf, 8, 8, 0xAABBCCDD00112233ULL) == 1,
              "write u64 succeeds");
        v = aowl_scene_read_bits(buf, 8, 8, &ok);
        CHECK(ok == 1 && v == 0xAABBCCDD00112233ULL, "read back the u64");

        ok = 99;
        v = aowl_scene_read_bits(buf, 0, 3, &ok);
        CHECK(ok == 0 && v == 0, "read with bad width n=3 -> ok=0, value 0");
    }

    /* --- verify-RVA declines gracefully with no GameAssembly.dll --- */
    CHECK(aowl_scene_target_count() == 5, "5 scene targets declared");
    CHECK(aowl_scene_fn(0) == NULL, "aowl_scene_fn declines (no GameAssembly)");
    CHECK(aowl_scene_fn(-1) == NULL, "aowl_scene_fn(-1) declines, no OOB read");
    CHECK(aowl_scene_fn(99) == NULL, "aowl_scene_fn(99) declines, no OOB read");
    CHECK(strcmp(aowl_scene_name(AOWL_SCENE_FIND),
                 "UnityEngine.Transform::Find") == 0, "target names intact");

    if (fails == 0) { printf("\nALL SCENE PURE-LOGIC CHECKS PASS\n"); return 0; }
    printf("\n%d CHECK(S) FAILED\n", fails);
    return 1;
}
