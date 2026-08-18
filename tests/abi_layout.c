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
    CHECK("sizeof(AowlHostApi)", sizeof(AowlHostApi), 168);
    CHECK("sizeof(AowlModInfo)", sizeof(AowlModInfo), 104);
    CHECK("sizeof(AowlModApi)", sizeof(AowlModApi), 56);

    /* Offsets of the fields most likely to drift when the struct grows. */
    CHECK("offsetof(AowlHostApi, ctx)", offsetof(AowlHostApi, ctx), 8);
    CHECK("offsetof(AowlHostApi, info)", offsetof(AowlHostApi, info), 16);
    CHECK("offsetof(AowlHostApi, alloc)", offsetof(AowlHostApi, alloc), 24);
    CHECK("offsetof(AowlHostApi, now_ms)", offsetof(AowlHostApi, now_ms), 160);

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
    CHECK("AOWLSPT_SIDE_SIM", AOWLSPT_SIDE_SIM, 3);
    CHECK("AOWLSPT_PATCH_SKIP", AOWLSPT_PATCH_SKIP, 1);

    if (failures == 0) {
        printf("all layout checks passed\n");
        return 0;
    }
    printf("%d layout check(s) FAILED\n", failures);
    return 1;
}
