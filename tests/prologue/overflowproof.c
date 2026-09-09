/* FORCED-OVERFLOW PROOF (CLAUDE.md 9b).
 *
 * The claim under test: after the fix, a verify that fails because OUR snapshot
 * table is full is DISTINGUISHABLE from a verify that fails because the bytes
 * differ. Before the fix both returned a bare 0.
 *
 * The check is falsifiable by construction: if the two paths still produced the
 * same reason, or if the health line read the same in both states, this exits
 * non-zero. It deliberately drives the table to overflow rather than hoping.
 *
 * AOWL_PRO_MAX_ROWS is forced to 4 here so the overflow is reached in four
 * calls. The real bound is restored by simply not defining it. */
#define AOWL_PRO_MAX_ROWS 4
#include <stdio.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "aowlspt_prologue.h"

static int fails = 0;
static void expect(int cond, const char* what) {
    printf("%-5s %s\n", cond ? "PASS" : "FAIL", what);
    if (!cond) fails++;
}

int main(void) {
    unsigned char sig_match[16], sig_diff[16];
    int i;
    char full_line[1024], ok_line[1024];

    memset(sig_match, 0xAB, sizeof(sig_match));
    memset(sig_diff,  0xCD, sizeof(sig_diff));

    /* Seat rows by hand. Capture needs GameAssembly.dll, which is not in this
     * process -- but the table is the same static array the host uses, and the
     * two failure paths under test are both downstream of it. Seating directly
     * is the only way to exercise a MISMATCH without the game. */
    for (i = 0; i < AOWL_PRO_MAX_ROWS; i++) {
        aowl_pro_rows[i].rva = 0x1000u + (uint32_t)i;
        memcpy(aowl_pro_rows[i].b, sig_match, 16);
        aowl_pro_rows[i].len = 16;
        aowl_pro_rows[i].used = 1;
        aowl_pro_used++;
    }
    printf("table seated: %d/%d rows\n\n", aowl_pro_rows_used(), aowl_pro_capacity());

    /* 1. A row that EXISTS and matches. */
    expect(aowl_pro_verify(0x1000u, sig_match, 16) == 1, "matching sig verifies");
    expect(aowl_pro_last_reason() == AOWL_PRO_R_OK, "  reason == R_OK");

    /* 2. A row that EXISTS and does NOT match -- the REAL mismatch. */
    expect(aowl_pro_verify(0x1000u, sig_diff, 16) == 0, "differing sig refuses");
    expect(aowl_pro_last_reason() == AOWL_PRO_R_MISMATCH, "  reason == R_MISMATCH");
    printf("      -> \"%s\"\n", aowl_pro_last_reason_text());
    strncpy(ok_line, aowl_pro_health_line(), sizeof(ok_line) - 1);
    ok_line[sizeof(ok_line)-1] = 0;
    expect(aowl_pro_full_count() == 0, "  a mismatch does NOT count as an overflow");

    /* 3. An UNSEEN rva against a FULL table -- the failure that used to be
     *    indistinguishable from case 2. */
    expect(aowl_pro_verify(0x9999u, sig_match, 16) == 0, "unseen rva on a FULL table refuses");
    expect(aowl_pro_last_reason() == AOWL_PRO_R_TABLE_FULL, "  reason == R_TABLE_FULL");
    expect(aowl_pro_last_was_table_full() == 1, "  aowl_pro_last_was_table_full() == 1");
    printf("      -> \"%s\"\n", aowl_pro_last_reason_text());

    /* 4. THE POINT: the two reasons are not equal. */
    expect(AOWL_PRO_R_MISMATCH != AOWL_PRO_R_TABLE_FULL,
           "R_MISMATCH and R_TABLE_FULL are distinct codes");
    expect(strcmp(aowl_pro_reason_text(AOWL_PRO_R_MISMATCH),
                  aowl_pro_reason_text(AOWL_PRO_R_TABLE_FULL)) != 0,
           "their texts differ");

    /* 5. The dropped rva is NAMED, and the startup line shouts. */
    expect(aowl_pro_dropped_count() == 1, "the dropped rva was recorded");
    expect(aowl_pro_dropped_at(0) == 0x9999u, "  and it is the right one (0x9999)");
    strncpy(full_line, aowl_pro_health_line(), sizeof(full_line) - 1);
    full_line[sizeof(full_line)-1] = 0;
    expect(strstr(full_line, "OVERFLOWED") != NULL, "health line shouts OVERFLOWED");
    expect(strstr(full_line, "0x9999") != NULL, "  and names the dropped rva");
    expect(strcmp(full_line, ok_line) != 0, "  and differs from the healthy line");
    printf("\nHEALTHY LINE: %s\n", ok_line);
    printf("OVERFLOW LINE: %s\n", full_line);

    /* 6. A verify that succeeds afterwards clears the reason -- so a stale
     *    R_TABLE_FULL can never make a later mismatch look like exhaustion. */
    expect(aowl_pro_verify(0x1001u, sig_match, 16) == 1, "a later good verify still passes");
    expect(aowl_pro_last_was_table_full() == 0, "  and the table-full flag is cleared");

    printf("\n%s (%d failure(s))\n", fails ? "OVERALL: FAIL" : "OVERALL: PASS", fails);
    return fails ? 1 : 0;
}
