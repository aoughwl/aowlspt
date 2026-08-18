#include "aowlspt_overlay.h"
int32_t aowlspt_nim_patch_fired(int32_t s, void* r){(void)s;(void)r;return 0;}
int main(void){ return aowl_ov_start(0x2D, 0) ? 0 : 1; }
