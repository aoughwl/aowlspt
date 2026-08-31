/* Instrument: count the DISTINCT RVAs the eager prologue-snapshot pass would
 * register, by including the very same abi headers the host TU includes and
 * walking the very same tables. No game required -- we never capture, we only
 * enumerate keys. */
#include <stdio.h>
#include <windows.h>
#include <stdint.h>
#include <string.h>

#include "aowlspt_shim.h"
#include "aowlspt_prologue.h"
#include "aowlspt_debugui.h"
#include "aowlspt_modetext.h"
#include "aowlspt_botnav.h"
#include "aowlspt_navui.h"
#include "aowlspt_nativeui.h"
#include "aowlspt_natraid.h"
#include "aowlspt_camera.h"
#include "aowlspt_cursor.h"
#include "aowlspt_modeskip.h"
#include "aowlspt_uistate.h"
#include "aowlspt_pact.h"

static uint32_t seen[4096]; static int nseen = 0;
static int add(uint32_t r, const char* who, const char* nm) {
    int i; for (i = 0; i < nseen; i++) if (seen[i] == r) { printf("   dup  %-22s 0x%x (%s)\n", who, r, nm?nm:""); return 0; }
    seen[nseen++] = r;
    printf("%4d %-22s 0x%-9x %s\n", nseen, who, r, nm?nm:"");
    return 1;
}
int main(void) {
    int i;
    printf("--- eager registration order (aowl_pro_prime_all) ---\n");
    for (i = 0; i < aowl_du_target_count(); i++)  add(aowl_du_rva(i), "debugui", aowl_du_name(i));
    for (i = 0; i < aowl_mtx_target_count(); i++) add(aowl_mtx_rva(i), "modetext", NULL);
    add(aowl_du_preloader_update_rva(), "du/PreloaderUI.Update", NULL);
    for (i = 0; i < aowl_botnav_target_count(); i++) add(aowl_botnav_targets[i].rva, "botnav", aowl_botnav_targets[i].name);
    add(AOWL_BN_GOTOPOINT_RVA, "botnav/GoToPoint", NULL);
    add(AOWL_BN_STOPMOVE_RVA, "botnav/StopMove", NULL);
    add(AOWL_BN_SETSPEED_RVA, "botnav/SetSpeed", NULL);
    for (i = 0; i < aowl_nav_target_count(); i++) add(aowl_nav_target_rva(i), "navui", aowl_nav_target_name(i));
    for (i = 0; i < aowl_nu_target_count(); i++) add(aowl_nu_targets[i].rva, "nativeui", aowl_nu_targets[i].name);
    for (i = 0; i < aowl_nr_target_count(); i++) add(aowl_nr_targets[i].rva, "natraid", aowl_nr_targets[i].name);
    printf("DISTINCT EAGER RVAs = %d   (AOWL_PRO_MAX_ROWS = %d)\n\n", nseen, AOWL_PRO_MAX_ROWS);
    printf("--- lazy-only tables: captured on FIRST VERIFY, i.e. AFTER all of the above ---\n");
    for (i = 0; i < aowl_cam_target_count(); i++)  add(aowl_cam_targets[i].rva, "camera", aowl_cam_targets[i].name);
    for (i = 0; i < aowl_cur_target_count(); i++)  add(aowl_cur_targets[i].rva, "cursor", aowl_cur_targets[i].name);
    for (i = 0; i < aowl_msk_target_count(); i++)  add(aowl_msk_targets[i].rva, "modeskip", aowl_msk_targets[i].name);
    for (i = 0; i < AOWL_UI_TARGET_COUNT; i++)     add(aowl_ui_targets[i].rva, "uistate", aowl_ui_targets[i].name);
    for (i = 0; i < aowl_pact_target_count(); i++) add(aowl_pact_targets[i].rva, "pact", aowl_pact_targets[i].name);
    printf("\nLAZY TABLE COUNTS: cam=%d cur=%d msk=%d ui=%d pact=%d\n",
        aowl_cam_target_count(), aowl_cur_target_count(), aowl_msk_target_count(),
        (int)AOWL_UI_TARGET_COUNT, aowl_pact_target_count());
    printf("\nTABLE COUNTS: du=%d mtx=%d botnav=%d nav=%d nu=%d nr=%d\n",
        aowl_du_target_count(), aowl_mtx_target_count(), aowl_botnav_target_count(),
        aowl_nav_target_count(), aowl_nu_target_count(), aowl_nr_target_count());
    printf("DISTINCT EAGER RVAs = %d   (AOWL_PRO_MAX_ROWS = %d)\n", nseen, AOWL_PRO_MAX_ROWS);
    return 0;
}
