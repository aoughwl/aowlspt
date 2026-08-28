/* sharetest.c -- the falsifiability proof for the shared-RVA detour gate.
 *
 * The by-name path already refused a folded detour. The `@0x` path did not:
 * the most explicit way to name a target was the only unguarded one. This
 * exercises `aowl_nameidx_share_for_rva`, the lookup that closes it, against a
 * hand-built index whose contents are known exactly.
 *
 * The bad input is an RVA several keys fold onto -- 0x628110, the universal
 * stub, standing in for the 6,261 folded RVAs on this build. The good input is
 * an RVA one key owns. And the third case is the one that matters most: an RVA
 * the index has NO entry for must answer UNKNOWN (0), never "unshared".
 *
 * Build (PowerShell):
 *   gcc -I abi -o build/sharetest.exe tools/sharetest.c && build/sharetest.exe
 */
#include <stdio.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "aowlspt_nameindex.h"

static int fails = 0, passes = 0;
static void expect(const char *what, uint32_t rva, uint32_t want) {
    uint32_t got = aowl_nameidx_share_for_rva(rva);
    if (got == want) { passes++; printf("PASS  %-44s -> share=%u\n", what, got); }
    else { fails++; printf("FAIL  %-44s -> share=%u (wanted %u)\n",
                           what, got, want); }
}

#define N 6
int main(void) {
    size_t bytes = AOWL_NIDX_HEADER + (size_t)N * (8 + 4 + 4 + 2);
    unsigned char *buf = (unsigned char *)calloc(1, bytes);
    uint64_t *h  = (uint64_t *)(buf + AOWL_NIDX_HEADER);
    uint32_t *r  = (uint32_t *)(buf + AOWL_NIDX_HEADER + (size_t)N * 8);
    uint32_t *c  = (uint32_t *)(buf + AOWL_NIDX_HEADER + (size_t)N * 12);
    uint16_t *sh = (uint16_t *)(buf + AOWL_NIDX_HEADER + (size_t)N * 16);
    int i;
    for (i = 0; i < N; i++) { h[i] = (uint64_t)i + 1; c[i] = 0; }
    /* three keys folded onto the universal stub, as ForceMeshUpdate is */
    r[0] = 0x628110u; sh[0] = 6438;
    r[1] = 0x628110u; sh[1] = 6438;
    r[2] = 0x628110u; sh[2] = 6438;
    /* a method that owns its address */
    r[3] = 0x52A8510u; sh[3] = 1;
    /* two DIFFERENT keys on one address, each claiming share==1. The count is
     * still 2, and reporting 1 here would be a check that cannot fail. */
    r[4] = 0x0700000u; sh[4] = 1;
    r[5] = 0x0700000u; sh[5] = 1;

    printf("-- with no index loaded, everything is UNKNOWN --\n");
    aowl_nidx_ok = 0; aowl_nidx_buf = 0; aowl_nidx_count = 0;
    expect("0x628110 before the index is loaded", 0x628110u, 0);

    aowl_nidx_buf = buf; aowl_nidx_count = N; aowl_nidx_ok = 1;

    printf("-- the gate must FIRE on these --\n");
    expect("0x628110 (universal stub, 6438 owners)", 0x628110u, 6438);
    expect("two distinct keys each claiming share==1", 0x0700000u, 2);

    printf("-- the gate must NOT fire on this --\n");
    expect("0x52A8510 (one owner)", 0x52A8510u, 1);

    printf("-- absence is UNKNOWN, never 'unshared' --\n");
    expect("an RVA with no entry at all", 0x0DEAD00u, 0);
    expect("rva 0 (no address given)", 0u, 0);
    if (aowl_nameidx_share_for_rva(0x0DEAD00u) == AOWL_NIDX_SHARE_UNKNOWN) {
        passes++; printf("PASS  the absent answer IS the UNKNOWN sentinel, so "
                         "the host's refusal path sees it\n");
    } else { fails++; printf("FAIL  absent != UNKNOWN sentinel\n"); }

    printf("\n%d PASS, %d FAIL\n", passes, fails);
    return fails ? 1 : 0;
}
