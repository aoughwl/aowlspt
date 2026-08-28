/* alivetest.c -- the falsifiability proof for the Unity fake-null guard.
 *
 * Builds the bad inputs by hand -- a DESTROYED wrapper (readable, m_CachedPtr
 * zeroed, exactly what Destroy leaves behind), and a random non-zero pointer of
 * the kind a token-gated il2cpp export returns -- and asserts the predicate
 * FIRES on both. Then builds a LIVE wrapper and asserts it does NOT.
 *
 * The point being proved is the one readability cannot see: the destroyed
 * wrapper passes `aowl_is_readable(obj, 0x20)`, every time. That is the
 * `duOk`-shaped check that cannot fail.
 *
 * Build (PowerShell):
 *   gcc -I abi -o build/alivetest.exe tools/alivetest.c && build/alivetest.exe
 */
#include <stdio.h>
#include <windows.h>
#include <stdint.h>

/* The same VirtualQuery-based readability the host uses; defined before the
 * header so the header's forward declaration resolves to it. */
static int32_t aowl_is_readable(void *p, int32_t size) {
    MEMORY_BASIC_INFORMATION mbi;
    unsigned long long end;
    if (!p || size <= 0) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
    end = (unsigned long long)(uintptr_t)mbi.BaseAddress + mbi.RegionSize;
    return ((unsigned long long)(uintptr_t)p + (unsigned long long)size <= end);
}
#include "aowlspt_ualive.h"

static int fails = 0, passes = 0;
static void expect(const char *what, void *obj, int want) {
    int got = aowl_unity_alive_ex(obj);
    if (got == want) { passes++; printf("PASS  %-42s -> %s\n", what,
                                        aowl_unity_alive_name(got)); }
    else { fails++; printf("FAIL  %-42s -> %s (wanted %s)\n", what,
                           aowl_unity_alive_name(got),
                           aowl_unity_alive_name(want)); }
}

int main(void) {
    /* A managed object: {klass, monitor, m_CachedPtr}. `klass` points at
     * something mapped, as a real one does. */
    static unsigned char klassblob[64];
    unsigned long long live[4], dead[4];
    live[0] = (unsigned long long)(uintptr_t)klassblob;   /* klass       */
    live[1] = 0;                                          /* monitor     */
    live[2] = (unsigned long long)(uintptr_t)klassblob;   /* m_CachedPtr */
    live[3] = 0;
    dead[0] = (unsigned long long)(uintptr_t)klassblob;
    dead[1] = 0;
    dead[2] = 0;      /* <-- THE ONLY DIFFERENCE. This is what Destroy does. */
    dead[3] = 0;

    printf("-- the premise: readability cannot tell these apart --\n");
    if (aowl_is_readable(live, 0x20) && aowl_is_readable(dead, 0x20)) {
        passes++; printf("PASS  aowl_is_readable(obj,0x20) says YES to BOTH "
                         "the live and the DESTROYED wrapper\n");
    } else { fails++; printf("FAIL  the premise does not hold; this test "
                             "proves nothing\n"); }

    printf("-- the guard must FIRE on these --\n");
    expect("destroyed wrapper (m_CachedPtr == 0)", dead, AOWL_ALIVE_NO);
    expect("random non-zero (gated-export return)",
           (void *)(uintptr_t)0x9E3779B97F4A7C15ull, AOWL_ALIVE_UNKNOWN);
    expect("small non-zero garbage", (void *)(uintptr_t)0x2A, AOWL_ALIVE_UNKNOWN);
    expect("NULL", (void *)0, AOWL_ALIVE_UNKNOWN);

    printf("-- the guard must NOT fire on this --\n");
    expect("live wrapper", live, AOWL_ALIVE_YES);

    printf("-- the yes/no collapse --\n");
    if (aowl_unity_alive(live) == 1 && aowl_unity_alive(dead) == 0 &&
        aowl_unity_alive((void *)(uintptr_t)0x9E3779B97F4A7C15ull) == 0) {
        passes++; printf("PASS  UNKNOWN collapses to NO -- 'I could not look' "
                         "never opens the gate\n");
    } else { fails++; printf("FAIL  UNKNOWN does not collapse to NO\n"); }

    printf("\n%d PASS, %d FAIL\n", passes, fails);
    return fails ? 1 : 0;
}
