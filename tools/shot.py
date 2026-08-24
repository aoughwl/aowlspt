#!/usr/bin/env python3
"""shot.py -- screenshot the EscapeFromTarkov window, by HWND, unfocused.

    python tools/shot.py                       # whole window
    python tools/shot.py --crop 100,100,800,600
    python tools/shot.py --out C:\\path\\out.png
    python tools/shot.py --max-width 1600

USAGE DISCIPLINE -- READ THIS BEFORE CALLING IT
------------------------------------------------
A screenshot is the MOST EXPENSIVE action available in this toolbox: it costs
an order of magnitude more tokens to read back than any field read, and
CLAUDE.md section 2 forbids using one to answer a question the live inspector
can answer with `read`/`label`/`find`/`state`. Use it ONLY for genuinely
VISUAL questions -- layout, overlap, "does this look right", "where on
screen is this control" -- never as a substitute for a field read, and never
to check whether something merely EXISTS (use `find`/`findtext` for that).

METHOD
------
Windows only. Finds the EscapeFromTarkov top-level window by process name
(EscapeFromTarkov.exe), then captures it with `PrintWindow(hwnd, hdc,
PW_RENDERFULLCONTENT=0x2)` via ctypes (user32 + gdi32), which is the ONLY
reliable path for a DirectX/Unity window that is not focused or not in the
foreground -- plain `BitBlt` composites from the desktop's own backing store
and is reliably black or stale for exclusive/flip-model swapchains. If
PrintWindow's DIB comes back solid (near-zero variance in sampled pixels,
see `_looks_blank`), this falls back to a plain `BitBlt` capture and SAYS
which path produced the final image (`"method"` field), and if BOTH paths
produce a near-uniform image this is reported as a FAILURE (`ok: false`),
never handed back silently as if it were a real capture.

No third-party dependencies: a minimal PNG encoder (struct + zlib, stdlib
only) writes the file directly from the raw BGRA/RGB buffer.
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import struct
import sys
import time
import zlib

user32 = ctypes.windll.user32 if sys.platform == "win32" else None
gdi32 = ctypes.windll.gdi32 if sys.platform == "win32" else None
kernel32 = ctypes.windll.kernel32 if sys.platform == "win32" else None

PW_RENDERFULLCONTENT = 0x00000002
SRCCOPY = 0x00CC0020
DIB_RGB_COLORS = 0

SCRATCH_DEFAULT = os.path.join(
    os.environ.get("TEMP", "."), "aowlspt-shots")


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
        ("biPlanes", wt.WORD), ("biBitCount", wt.WORD),
        ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
        ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG),
        ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER),
                ("bmiColors", wt.DWORD * 3)]


def _find_hwnd(process_name="EscapeFromTarkov.exe"):
    """Enumerate top-level windows, match the one owned by a process whose
    image name matches (case-insensitive). Returns (hwnd, title) or
    (None, reason)."""
    target = process_name.lower()
    found = []

    WNDENUMPROC = ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)

    def cb(hwnd, lparam):
        if not user32.IsWindowVisible(hwnd):
            return True
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        hproc = kernel32.OpenProcess(0x1000 | 0x0400, False, pid.value)
        if not hproc:
            return True
        buf = ctypes.create_unicode_buffer(260)
        size = wt.DWORD(260)
        ok = ctypes.windll.kernel32.QueryFullProcessImageNameW(
            hproc, 0, buf, ctypes.byref(size))
        kernel32.CloseHandle(hproc)
        if not ok:
            return True
        name = os.path.basename(buf.value).lower()
        if name == target:
            length = user32.GetWindowTextLengthW(hwnd)
            tbuf = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, tbuf, length + 1)
            found.append((hwnd, tbuf.value))
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    if not found:
        return None, "no visible top-level window owned by %s" % process_name
    # Prefer one with a non-empty title (the real game window over any
    # helper/launcher window sharing the process).
    found.sort(key=lambda t: (t[1] == "", ), reverse=False)
    return found[0][0], found[0][1]


def _get_client_rect_size(hwnd):
    rect = wt.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    return rect.right - rect.left, rect.bottom - rect.top


def _capture_via(hwnd, use_printwindow):
    """Returns (ok, bgra_bytes_or_None, w, h, reason)."""
    w, h = _get_client_rect_size(hwnd)
    if w <= 0 or h <= 0:
        return False, None, 0, 0, "client rect is %dx%d (minimized or zero-size)" % (w, h)

    hwindow_dc = user32.GetDC(hwnd)
    mem_dc = gdi32.CreateCompatibleDC(hwindow_dc)
    bmp = gdi32.CreateCompatibleBitmap(hwindow_dc, w, h)
    gdi32.SelectObject(mem_dc, bmp)

    if use_printwindow:
        ok = user32.PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT)
        method_ok = bool(ok)
    else:
        # BitBlt from the window DC into our compatible DC -- the fallback,
        # known to composite black for flip-model DX/Unity swapchains.
        method_ok = bool(gdi32.BitBlt(mem_dc, 0, 0, w, h, hwindow_dc, 0, 0, SRCCOPY))

    if not method_ok:
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mem_dc)
        user32.ReleaseDC(hwnd, hwindow_dc)
        return False, None, w, h, "%s returned failure" % (
            "PrintWindow" if use_printwindow else "BitBlt")

    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -h  # top-down
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    bmi.bmiHeader.biCompression = 0  # BI_RGB

    buf_size = w * h * 4
    buf = (ctypes.c_byte * buf_size)()
    got = gdi32.GetDIBits(mem_dc, bmp, 0, h, buf, ctypes.byref(bmi), DIB_RGB_COLORS)

    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem_dc)
    user32.ReleaseDC(hwnd, hwindow_dc)

    if got == 0:
        return False, None, w, h, "GetDIBits returned 0 rows"
    return True, bytes(buf), w, h, ""


def _looks_blank(bgra, w, h, sample=400):
    """Sample pixels across the buffer; near-zero variance means a solid
    (usually black) capture, the known BitBlt-on-flip-model failure mode.
    Returns (blank, mean_luminance)."""
    n = w * h
    if n == 0:
        return True, 0.0
    step = max(1, n // sample)
    vals = []
    for i in range(0, n, step):
        off = i * 4
        b, g, r = bgra[off], bgra[off + 1], bgra[off + 2]
        vals.append((r + g + b) / 3.0)
    mean = sum(vals) / len(vals)
    variance = sum((v - mean) ** 2 for v in vals) / len(vals)
    # A genuinely uniform loading-screen frame is possible but rare; a
    # variance this low combined with a capture path known to composite
    # black is the actual failure signature we are guarding against.
    return variance < 1.0, mean


def _crop_bgra(bgra, w, h, crop):
    cx, cy, cw, ch_ = crop
    cx = max(0, min(cx, w))
    cy = max(0, min(cy, h))
    cw = max(1, min(cw, w - cx))
    ch_ = max(1, min(ch_, h - cy))
    out = bytearray(cw * ch_ * 4)
    for row in range(ch_):
        src_off = ((cy + row) * w + cx) * 4
        dst_off = row * cw * 4
        out[dst_off:dst_off + cw * 4] = bgra[src_off:src_off + cw * 4]
    return bytes(out), cw, ch_


def _downscale_bgra(bgra, w, h, max_width):
    if w <= max_width:
        return bgra, w, h
    new_w = max_width
    new_h = max(1, int(h * new_w / w))
    out = bytearray(new_w * new_h * 4)
    for ny in range(new_h):
        sy = min(h - 1, ny * h // new_h)
        src_row = sy * w * 4
        dst_row = ny * new_w * 4
        for nx in range(new_w):
            sx = min(w - 1, nx * w // new_w)
            out[dst_row + nx * 4:dst_row + nx * 4 + 4] = \
                bgra[src_row + sx * 4:src_row + sx * 4 + 4]
    return bytes(out), new_w, new_h


# ---------------------------------------------------------------------------
# Minimal PNG encoder: stdlib only (struct + zlib), truecolor RGB (no alpha
# channel needed for a screenshot; BGRA -> RGB on the way in).
# ---------------------------------------------------------------------------

def _png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data +
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, bgra, w, h):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0, per scanline
        row_off = y * w * 4
        for x in range(w):
            off = row_off + x * 4
            b, g, r = bgra[off], bgra[off + 1], bgra[off + 2]
            raw += bytes((r, g, b))
    compressed = zlib.compress(bytes(raw), 6)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_png_chunk(b"IHDR", ihdr))
        f.write(_png_chunk(b"IDAT", compressed))
        f.write(_png_chunk(b"IEND", b""))


def capture(process_name="EscapeFromTarkov.exe", crop=None, max_width=1200,
            out_dir=None, out_path=None):
    """Returns a result dict, never raises for an expected failure mode --
    every failure is `ok: false` with a `reason`, never a silently-returned
    black image."""
    if sys.platform != "win32":
        return {"ok": False, "reason": "shot.py only supports Windows (PrintWindow/BitBlt)"}

    hwnd, title_or_reason = _find_hwnd(process_name)
    if hwnd is None:
        return {"ok": False, "reason": title_or_reason}

    ok, bgra, w, h, reason = _capture_via(hwnd, use_printwindow=True)
    method = "PrintWindow(PW_RENDERFULLCONTENT)"
    if ok:
        blank, mean = _looks_blank(bgra, w, h)
    else:
        blank, mean = True, 0.0

    if not ok or blank:
        ok2, bgra2, w2, h2, reason2 = _capture_via(hwnd, use_printwindow=False)
        if ok2:
            blank2, mean2 = _looks_blank(bgra2, w2, h2)
        else:
            blank2, mean2 = True, 0.0
        if ok2 and not blank2:
            ok, bgra, w, h, method = True, bgra2, w2, h2, "BitBlt (fallback)"
            blank, mean = blank2, mean2
        elif not ok:
            return {"ok": False, "reason": "PrintWindow failed (%s) and BitBlt fallback also failed (%s)"
                    % (reason, reason2)}
        else:
            # PrintWindow produced pixels but they were blank, and BitBlt's
            # fallback was ALSO blank/failed -- report failure honestly
            # rather than handing back a black PNG as if it were real.
            return {"ok": False, "reason": ("both PrintWindow and BitBlt produced a "
                     "near-uniform (likely black) image -- mean_luminance=%.2f via "
                     "PrintWindow, %.2f via BitBlt fallback (%s). The window may be "
                     "minimized, off-screen, or using a capture-hostile swapchain "
                     "mode." % (mean, mean2, reason2 or "no error")),
                    "mean_luminance_printwindow": round(mean, 2),
                    "mean_luminance_bitblt": round(mean2, 2)}

    if crop:
        bgra, w, h = _crop_bgra(bgra, w, h, crop)
    bgra, w, h = _downscale_bgra(bgra, w, h, max_width)
    _, mean_final = _looks_blank(bgra, w, h)

    if out_path is None:
        d = out_dir or SCRATCH_DEFAULT
        os.makedirs(d, exist_ok=True)
        out_path = os.path.join(d, "shot-%d.png" % int(time.time() * 1000))
    else:
        os.makedirs(os.path.dirname(os.path.abspath(out_path)) or ".", exist_ok=True)

    write_png(out_path, bgra, w, h)

    return {
        "ok": True, "path": out_path, "width": w, "height": h,
        "method": method, "window_title": title_or_reason,
        "mean_luminance": round(mean_final, 2),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--process", default="EscapeFromTarkov.exe")
    ap.add_argument("--crop", default=None, help="x,y,w,h")
    ap.add_argument("--max-width", type=int, default=1200)
    ap.add_argument("--out", default=None)
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    crop = None
    if args.crop:
        parts = [int(x) for x in args.crop.split(",")]
        if len(parts) != 4:
            print(json.dumps({"ok": False, "reason": "--crop wants x,y,w,h"}))
            return 1
        crop = tuple(parts)

    result = capture(process_name=args.process, crop=crop, max_width=args.max_width,
                      out_dir=args.out_dir, out_path=args.out)
    print(json.dumps(result, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
