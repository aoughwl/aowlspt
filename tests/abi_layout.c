/* The C side of the layout check.
 *
 * Prints the sizes and offsets the real compiler gives the real header, so the
 * nimony expectations in abi_layout.nim are checked against the header itself
 * rather than against a second copy of somebody's arithmetic.
 *
 * Build: gcc -I../abi -o abi_layout_c abi_layout.c
 */

#include <stdio.h>
#include <stddef.h>
#include "aowlspt_abi.h"

int main(void)
{
    int failures = 0;

#define CHECK(label, got, want)                                              \
    do {                                                                     \
        long g = (long)(got), w = (long)(want);                              \
        if (g == w) {                                                        \
            printf("  ok    %s = %ld\n", label, g);                          \
        } else {                                                             \
            printf("  FAIL  %s = %ld, expected %ld\n", label, g, w);         \
            failures++;                                                      \
        }                                                                    \
    } while (0)

    printf("aowlspt ABI layout, from the C header\n");

    CHECK("sizeof(AowlSlice)", sizeof(AowlSlice), 16);
    CHECK("sizeof(AowlBuffer)", sizeof(AowlBuffer), 16);
    CHECK("sizeof(AowlHostInfo)", sizeof(AowlHostInfo), 120);
    CHECK("sizeof(AowlHostApi)", sizeof(AowlHostApi), 232);
    /* The typed patch frame. A mod reads this struct's fields directly rather
     * than through accessor function pointers -- that is what makes an argument
     * read a load instead of a cross-module indirect call -- so its layout is
     * as much a part of the ABI as `AowlHostApi`'s. */
    CHECK("sizeof(AowlPatchFrame)", sizeof(AowlPatchFrame), 48);
    CHECK("sizeof(AowlModInfo)", sizeof(AowlModInfo), 104);
    CHECK("sizeof(AowlModApi)", sizeof(AowlModApi), 56);

    /* Offsets of the fields most likely to drift when the struct grows. */
    CHECK("offsetof(AowlHostApi, ctx)", offsetof(AowlHostApi, ctx), 8);
    CHECK("offsetof(AowlHostApi, info)", offsetof(AowlHostApi, info), 16);
    CHECK("offsetof(AowlHostApi, alloc)", offsetof(AowlHostApi, alloc), 24);
    CHECK("offsetof(AowlHostApi, now_ms)", offsetof(AowlHostApi, now_ms), 160);
    /* Revision 2 appended `store_*` after `now_ms`. Checking the offset as well
     * as the size is what catches an insertion in the middle, which would keep
     * the size right and move every field a mod built against revision 1
     * reads. */
    CHECK("offsetof(AowlHostApi, store_get)", offsetof(AowlHostApi, store_get), 168);
    CHECK("offsetof(AowlHostApi, store_list)", offsetof(AowlHostApi, store_list), 184);
    /* Revision 3 appended `handle_pointer`/`handle_pin` after `store_list`. */
    CHECK("offsetof(AowlHostApi, handle_pointer)",
          offsetof(AowlHostApi, handle_pointer), 192);
    CHECK("offsetof(AowlHostApi, handle_pin)",
          offsetof(AowlHostApi, handle_pin), 200);
    /* Revision 4 appended `patch_typed`, revision 5 `notify_push`, revision 6
     * `invoke_render`. */
    CHECK("offsetof(AowlHostApi, patch_typed)",
          offsetof(AowlHostApi, patch_typed), 208);
    CHECK("offsetof(AowlHostApi, notify_push)",
          offsetof(AowlHostApi, notify_push), 216);
    CHECK("offsetof(AowlHostApi, invoke_render)",
          offsetof(AowlHostApi, invoke_render), 224);

    /* The per-revision sizes, which are what a mod tests a capability against.
     * They are literals in `aowl/src/aowlspt/abi.nim` -- they have to be, since
     * the whole point is that they do not move when the struct does -- so this
     * is the only place they are checked against the header they describe. Get
     * one wrong and a mod refuses a host that has exactly what it asked for. */
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV1", AOWLSPT_HOSTAPI_SIZE_REV1, 168);
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV2", AOWLSPT_HOSTAPI_SIZE_REV2, 192);
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV3", AOWLSPT_HOSTAPI_SIZE_REV3, 208);
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV4", AOWLSPT_HOSTAPI_SIZE_REV4, 216);
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV5", AOWLSPT_HOSTAPI_SIZE_REV5, 224);
    CHECK("AOWLSPT_HOSTAPI_SIZE_REV6", AOWLSPT_HOSTAPI_SIZE_REV6, 232);

    CHECK("offsetof(AowlHostInfo, host_name)", offsetof(AowlHostInfo, host_name), 16);
    CHECK("offsetof(AowlHostInfo, encodings)", offsetof(AowlHostInfo, encodings), 80);
    CHECK("offsetof(AowlHostInfo, mod_dir)", offsetof(AowlHostInfo, mod_dir), 88);
    CHECK("offsetof(AowlHostInfo, data_dir)", offsetof(AowlHostInfo, data_dir), 104);

    CHECK("offsetof(AowlModInfo, guid)", offsetof(AowlModInfo, guid), 16);
    CHECK("offsetof(AowlModInfo, sides)", offsetof(AowlModInfo, sides), 96);
    CHECK("offsetof(AowlModInfo, flags)", offsetof(AowlModInfo, flags), 100);

    CHECK("offsetof(AowlModApi, self)", offsetof(AowlModApi, self), 8);
    CHECK("offsetof(AowlModApi, state_load)", offsetof(AowlModApi, state_load), 48);

    CHECK("AOWLSPT_ABI_VERSION", AOWLSPT_ABI_VERSION, 1);
    CHECK("AOWLSPT_ABI_REVISION", AOWLSPT_ABI_REVISION, 6);
    CHECK("AOWLSPT_SIDE_SIM", AOWLSPT_SIDE_SIM, 3);
    CHECK("AOWLSPT_PATCH_SKIP", AOWLSPT_PATCH_SKIP, 1);

    /* The register-frame offsets `aowlspt_frame.h` reads by hand. They are a
     * copy of the thunk's assembly, and a copy is only safe while it is pinned;
     * `tests/detour_test.c` pins them to the assembly itself, and this pins the
     * numbers a mod's accessors compile against. */
    CHECK("AOWL_FRAME_OFF_GPR", AOWL_FRAME_OFF_GPR, 0x00);
    CHECK("AOWL_FRAME_OFF_XMM", AOWL_FRAME_OFF_XMM, 0x20);
    CHECK("AOWL_FRAME_OFF_RET", AOWL_FRAME_OFF_RET, 0x40);
    CHECK("AOWL_FRAME_OFF_RETF", AOWL_FRAME_OFF_RETF, 0x48);
    CHECK("AOWLSPT_ARG_OBJECT", AOWLSPT_ARG_OBJECT, 4);
    CHECK("AOWLSPT_ARG_STACK", AOWLSPT_ARG_STACK, 8);

    if (failures == 0) {
        printf("all layout checks passed\n");
        return 0;
    }
    printf("%d layout check(s) FAILED\n", failures);
    return 1;
}
