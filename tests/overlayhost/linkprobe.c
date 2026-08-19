/* linkprobe.c -- proves `abi/aowlspt_overlay.h` needs no extra link library.
 *
 * The claim it checks is load-bearing for the client host: adding the overlay
 * must not add `d3d11.dll` or `winhttp.dll` to the host DLL's import table.
 * The host is injected into a process that is mid-startup, and a failed
 * load-time import there is a silent load failure with nothing in the log --
 * so everything in the header is either a COM vtable call or a
 * `GetProcAddress`, and this file is how that stays true.
 *
 *   gcc -O1 -I../../abi linkprobe.c -o linkprobe.exe
 *
 * No -ld3d11, no -ldxgi, no -lwinhttp. If a future edit to the header adds a
 * direct call to an imported function, this stops linking.
 */
#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

/* Added alongside `aowlspt_nim_patch_fired` when `abi/aowlspt_detour.h` grew a
 * return-side dispatcher: the same rule applies -- the thunk pool is emitted
 * unconditionally, so any binary that includes the engine has to satisfy both
 * symbols. The overlay routes through neither; its detours are C functions with
 * the right signature, installed with `aowl_hook_install`. */
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

int main(void) {
    /* Starting it also exercises the probe device and both detour installs on
     * a process with no rendering of its own. */
    return aowl_ov_start(0x2D /* VK_INSERT */, 0) ? 0 : 1;
}
