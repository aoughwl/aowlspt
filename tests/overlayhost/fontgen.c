/* fontgen.c -- bakes the overlay's bitmap font into a C table at BUILD time.
 *
 * Why this exists rather than rasterising at runtime: the overlay runs inside
 * EscapeFromTarkov.exe, on the render thread, inside a hooked Present. Calling
 * into GDI there to build a font atlas means creating a DC, selecting a font
 * and allocating a DIB in a process whose GDI state belongs to Unity, on a
 * thread that is mid-frame. Doing it once at build time instead means the game
 * process touches nothing but a static array.
 *
 * Output: 95 glyphs (ASCII 32..126), 8x16 pixels, one byte per row, MSB = the
 * leftmost pixel. NONANTIALIASED_QUALITY so a pixel is on or off -- a 1-bit
 * table is a quarter the size of a coverage table and, at this cell size, a
 * grey edge just reads as blur.
 *
 * Run:  gcc -O2 fontgen.c -o fontgen.exe -lgdi32 && ./fontgen.exe > font.inc
 * The result is pasted into abi/aowlspt_overlay.h; it is not read at runtime.
 */
#include <windows.h>
#include <stdio.h>

#define CW 8
#define CH 16

int main(void) {
    HDC dc = CreateCompatibleDC(NULL);
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = CW;
    bi.bmiHeader.biHeight = -CH;          /* top-down, so row 0 is the top */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = NULL;
    HBITMAP bm = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    SelectObject(dc, bm);

    /* -13 is the height that makes Consolas fill a 16px cell without the
     * descenders of g/p/y being clipped by the cell below. Checked by eye on
     * the generated table, not assumed. */
    HFONT f = CreateFontA(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, ANSI_CHARSET,
                          OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                          NONANTIALIASED_QUALITY, FIXED_PITCH | FF_MODERN,
                          "Consolas");
    SelectObject(dc, f);
    SetBkColor(dc, RGB(0, 0, 0));
    SetTextColor(dc, RGB(255, 255, 255));
    SetBkMode(dc, OPAQUE);

    printf("static const uint8_t aowl_ov_font[95][16] = {\n");
    for (int c = 32; c <= 126; c++) {
        RECT r = { 0, 0, CW, CH };
        FillRect(dc, &r, (HBRUSH)GetStockObject(BLACK_BRUSH));
        char s[2]; s[0] = (char)c; s[1] = 0;
        TextOutA(dc, 0, 0, s, 1);
        GdiFlush();
        unsigned char rows[CH];
        for (int y = 0; y < CH; y++) {
            unsigned char m = 0;
            for (int x = 0; x < CW; x++) {
                unsigned int px = ((unsigned int*)bits)[y * CW + x];
                if ((px & 0xFF) > 127) m |= (unsigned char)(0x80u >> x);
            }
            rows[y] = m;
        }
        printf("  {");
        for (int y = 0; y < CH; y++)
            printf("0x%02X%s", rows[y], y == CH - 1 ? "" : ",");
        /* The glyph itself is not echoed into the comment: '*' and '/' would
         * close the comment early and '\' would eat the newline. */
        printf("}, /* %d */\n", c);
    }
    printf("};\n");
    return 0;
}
