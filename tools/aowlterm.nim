## Terminal for `aowlspt-launch`: what the console can do, and how to draw on it.
##
## The launcher is the only part of this project a player interacts with
## directly, and it has no window of its own -- there is no GUI launcher and
## there is not going to be one. So the console *is* the front end, and this is
## the part that finds out what that console is capable of before drawing
## anything on it.
##
## ## Three terminals, not one
##
## The same executable is started in three quite different places, and only one
## of them is a terminal that can be painted:
##
##   * **A real console with VT processing.** Double-clicked, or run from
##     Windows Terminal, PowerShell or cmd on any Windows 10 build since 1511.
##     Escape sequences work, the cursor can be moved, the screen can be
##     repainted. This is what the split log view needs.
##   * **A real console that would not take VT.** `SetConsoleMode` refusing
##     `ENABLE_VIRTUAL_TERMINAL_PROCESSING` is what a genuinely old console does,
##     and what some third-party console hosts do. Colour is still available
##     through `SetConsoleTextAttribute`, but nothing can be repainted, so the
##     views degrade to a scrolling transcript.
##   * **Not a console at all.** `aowlspt-launch > launch.txt`, a CI step, a
##     Discord user asked to paste their output. `GetConsoleMode` fails on the
##     handle. Here the *only* correct behaviour is plain lines with no escape
##     codes in them at all -- a launcher whose log is unreadable because it is
##     full of `ESC[2J` is a launcher nobody can be helped with.
##
## `termMode` answers which of the three this is, once, and everything else in
## here is written so that the plain case is the cheap case rather than an
## afterthought.
##
## ## Why the drawing is a whole-frame string
##
## Every frame is built into one string and handed to one `WriteFile`. Not
## because it is faster -- at ten frames a second nothing here is measurable --
## but because a frame written in pieces *tears*: the console shows half of the
## new frame under half of the old one for as long as the writes take, and on a
## machine loading a 41 MB database that is long enough to see. One write is one
## frame or none.
##
## Row width is tracked separately from row text (`Row.width`), because the text
## has colour escapes in it and `text.len` is therefore not what the terminal
## will show. Padding to a column with `text.len` is the bug that puts every
## right-hand border in a different place.

import std/[strutils, syncio]

{.emit: """
#include <windows.h>
#include <stdint.h>
#include <string.h>

/* Not from <consoleapi.h>: mingw's headers have carried these for years, but
 * the launcher is built by a rule it does not own and a missing define here is
 * a link error in somebody else's build. The values are ABI. */
#ifndef AOWL_ENABLE_VT_OUTPUT
#define AOWL_ENABLE_VT_OUTPUT 0x0004
#endif
#define AOWL_ENABLE_PROCESSED_INPUT 0x0001
#define AOWL_ENABLE_LINE_INPUT      0x0002
#define AOWL_ENABLE_ECHO_INPUT      0x0004
#define AOWL_ENABLE_WINDOW_INPUT    0x0008

static HANDLE aowl_t_out = NULL;
static HANDLE aowl_t_in  = NULL;
static DWORD  aowl_t_out_mode0 = 0;
static DWORD  aowl_t_in_mode0 = 0;
static UINT   aowl_t_cp0 = 0;
static int    aowl_t_out_console = 0;
static int    aowl_t_in_console = 0;
static int    aowl_t_vt = 0;
static int    aowl_t_utf8 = 0;
static int    aowl_t_raw = 0;
static int    aowl_t_ready = 0;
static volatile LONG aowl_t_intr = 0;

/* Ctrl+C is *caught*, not left to the default handler, and the handler returns
 * TRUE so the process is not torn down. The whole point is that quitting the
 * launcher has to stop the backend it started: a Ctrl+C that kills this process
 * where it stands leaves a server holding the store lock, and the next launch
 * refuses to start with a message about a lock rather than about the Ctrl+C
 * that caused it. So this sets a flag the main loop reads and unwinds through
 * the ordinary quit path. */
static BOOL WINAPI aowl_t_ctrl(DWORD kind) {
  (void)kind;
  aowl_t_intr = 1;
  return TRUE;
}

static int32_t aowl_term_init(void) {
  DWORD m = 0;
  if (aowl_t_ready)
    return aowl_t_out_console ? (aowl_t_vt ? 2 : 1) : 0;
  aowl_t_ready = 1;
  aowl_t_out = GetStdHandle(STD_OUTPUT_HANDLE);
  aowl_t_in  = GetStdHandle(STD_INPUT_HANDLE);
  if (aowl_t_out != NULL && aowl_t_out != INVALID_HANDLE_VALUE &&
      GetConsoleMode(aowl_t_out, &m)) {
    aowl_t_out_console = 1;
    aowl_t_out_mode0 = m;
    if (SetConsoleMode(aowl_t_out, m | AOWL_ENABLE_VT_OUTPUT))
      aowl_t_vt = 1;
    aowl_t_cp0 = GetConsoleOutputCP();
    /* Box drawing is UTF-8. A console left on codepage 437 renders it as
     * mojibake, which looks like a corrupt build rather than a wrong codepage,
     * so the fallback to ASCII borders is driven by whether this succeeded. */
    if (SetConsoleOutputCP(65001)) aowl_t_utf8 = 1;
  }
  m = 0;
  if (aowl_t_in != NULL && aowl_t_in != INVALID_HANDLE_VALUE &&
      GetConsoleMode(aowl_t_in, &m)) {
    aowl_t_in_console = 1;
    aowl_t_in_mode0 = m;
  }
  SetConsoleCtrlHandler(aowl_t_ctrl, TRUE);
  return aowl_t_out_console ? (aowl_t_vt ? 2 : 1) : 0;
}

static int32_t aowl_term_utf8(void)   { return aowl_t_utf8; }
static int32_t aowl_term_stdin_tty(void) { return aowl_t_in_console; }
static int32_t aowl_term_interrupted(void) { return (int32_t)aowl_t_intr; }
static void    aowl_term_clear_interrupt(void) { aowl_t_intr = 0; }

static void aowl_term_write(const char* s, int32_t n) {
  DWORD put = 0;
  int off = 0;
  if (!aowl_t_ready) aowl_term_init();
  if (aowl_t_out == NULL || aowl_t_out == INVALID_HANDLE_VALUE) return;
  while (off < n) {
    if (!WriteFile(aowl_t_out, s + off, (DWORD)(n - off), &put, NULL)) return;
    if (put == 0) return;
    off += (int)put;
  }
}

/* The *window*, not the buffer. A console with 9000 lines of scrollback has a
 * buffer that tall, and a frame drawn to the buffer height would be almost
 * entirely off-screen. */
static int32_t aowl_term_width(void) {
  CONSOLE_SCREEN_BUFFER_INFO ci;
  if (!aowl_t_ready) aowl_term_init();
  if (!aowl_t_out_console) return 0;
  if (!GetConsoleScreenBufferInfo(aowl_t_out, &ci)) return 0;
  return (int32_t)(ci.srWindow.Right - ci.srWindow.Left + 1);
}

static int32_t aowl_term_height(void) {
  CONSOLE_SCREEN_BUFFER_INFO ci;
  if (!aowl_t_ready) aowl_term_init();
  if (!aowl_t_out_console) return 0;
  if (!GetConsoleScreenBufferInfo(aowl_t_out, &ci)) return 0;
  return (int32_t)(ci.srWindow.Bottom - ci.srWindow.Top + 1);
}

/* Colour for the console that would not take VT. Bits are
 * FOREGROUND_BLUE|GREEN|RED|INTENSITY, so this takes them directly. */
static void aowl_term_attr(int32_t bits) {
  if (!aowl_t_out_console) return;
  SetConsoleTextAttribute(aowl_t_out, (WORD)bits);
}

/* Line input and echo off, so a keystroke arrives without Enter behind it and
 * does not appear in the middle of a frame. PROCESSED_INPUT stays on: it is
 * what routes Ctrl+C to the handler above, and without it Ctrl+C becomes a
 * 0x03 byte in the key queue that nothing would act on. */
static void aowl_term_raw(int32_t on) {
  if (!aowl_t_in_console) return;
  if (on) {
    DWORD m = aowl_t_in_mode0;
    m &= ~(DWORD)(AOWL_ENABLE_LINE_INPUT | AOWL_ENABLE_ECHO_INPUT);
    m |= (DWORD)(AOWL_ENABLE_PROCESSED_INPUT | AOWL_ENABLE_WINDOW_INPUT);
    if (SetConsoleMode(aowl_t_in, m)) aowl_t_raw = 1;
  } else if (aowl_t_raw) {
    SetConsoleMode(aowl_t_in, aowl_t_in_mode0);
    aowl_t_raw = 0;
  }
}

/* 0 nothing pending. An ASCII key as its own code. Anything with no ASCII form
 * (the arrows, page up, F-keys) as 0x1000 | virtual-key, which cannot collide
 * with the ASCII range. */
static int32_t aowl_term_key(void) {
  DWORD n = 0, got = 0;
  INPUT_RECORD r;
  if (!aowl_t_in_console) return 0;
  for (;;) {
    if (!GetNumberOfConsoleInputEvents(aowl_t_in, &n) || n == 0) return 0;
    if (!ReadConsoleInputA(aowl_t_in, &r, 1, &got) || got == 0) return 0;
    if (r.EventType == KEY_EVENT && r.Event.KeyEvent.bKeyDown) {
      unsigned char c = (unsigned char)r.Event.KeyEvent.uChar.AsciiChar;
      if (c != 0) return (int32_t)c;
      return 0x1000 | (int32_t)r.Event.KeyEvent.wVirtualKeyCode;
    }
  }
}

/* Everything this module changed about the console, put back. Called on every
 * exit path including the Ctrl+C one -- a console left in raw mode with VT on
 * and the alternate screen buffer showing is a shell the user has to close. */
static void aowl_term_restore(void) {
  if (!aowl_t_ready) return;
  aowl_term_raw(0);
  if (aowl_t_out_console) {
    if (aowl_t_cp0 != 0) SetConsoleOutputCP(aowl_t_cp0);
    SetConsoleMode(aowl_t_out, aowl_t_out_mode0);
  }
}

static void aowl_term_sleep(int32_t ms) { Sleep((DWORD)ms); }

/* ---------------------------------------------------------------- tailing
 *
 * Reopened by path on every read rather than held open, and that is the whole
 * design rather than laziness.
 *
 * Both logs are *replaced* when their writer starts: `modhost.openLog` calls
 * `writeTextFile`, which removes the old file and creates a new one. A handle
 * opened before that follows the file, not the path -- so a tailer that opened
 * the log first and held the handle would sit on an orphaned, deleted inode and
 * report that the backend never wrote anything, for ever, while the real log
 * filled up beside it. Reopening costs a few microseconds ten times a second
 * and cannot get this wrong.
 *
 * `stamp` is what notices the replacement: creation time mixed with the file
 * index, which together change when the file behind the path does. On a reset
 * the caller is told, because the lines it already has belong to a previous run
 * and showing them under the new one is worse than showing nothing. */
static int32_t aowl_tail_read(const char* path, int64_t* off, int64_t* stamp,
                              int32_t* wasReset, char* buf, int32_t cap) {
  HANDLE h;
  BY_HANDLE_FILE_INFORMATION fi;
  LARGE_INTEGER pos;
  DWORD got = 0;
  *wasReset = 0;
  h = CreateFileA(path, GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return -1;
  if (GetFileInformationByHandle(h, &fi)) {
    int64_t st = ((int64_t)(uint32_t)fi.ftCreationTime.dwHighDateTime << 32) |
                 (int64_t)(uint32_t)fi.ftCreationTime.dwLowDateTime;
    int64_t ix = ((int64_t)(uint32_t)fi.nFileIndexHigh << 32) |
                 (int64_t)(uint32_t)fi.nFileIndexLow;
    int64_t size = ((int64_t)(uint32_t)fi.nFileSizeHigh << 32) |
                   (int64_t)(uint32_t)fi.nFileSizeLow;
    st ^= ix;
    if (st != *stamp) {
      *stamp = st;
      /* Not a reset on the very first read: there is nothing to throw away
       * yet, and reporting one would make the caller clear a pane it has not
       * filled. */
      if (*off != 0) *wasReset = 1;
      *off = 0;
    }
    if (size < *off) { *off = 0; *wasReset = 1; }
  }
  pos.QuadPart = *off;
  if (!SetFilePointerEx(h, pos, NULL, FILE_BEGIN)) { CloseHandle(h); return -1; }
  if (!ReadFile(h, buf, (DWORD)cap, &got, NULL)) { CloseHandle(h); return -1; }
  CloseHandle(h);
  *off += (int64_t)got;
  return (int32_t)got;
}
""".}

proc cTermInit(): int32 {.importc: "aowl_term_init", nodecl.}
proc cTermUtf8(): int32 {.importc: "aowl_term_utf8", nodecl.}
proc cTermStdinTty(): int32 {.importc: "aowl_term_stdin_tty", nodecl.}
proc cTermInterrupted(): int32 {.importc: "aowl_term_interrupted", nodecl.}
proc cTermClearInterrupt() {.importc: "aowl_term_clear_interrupt", nodecl.}
proc cTermWrite(s: cstring; n: int32) {.importc: "aowl_term_write", nodecl.}
proc cTermWidth(): int32 {.importc: "aowl_term_width", nodecl.}
proc cTermHeight(): int32 {.importc: "aowl_term_height", nodecl.}
proc cTermAttr(bits: int32) {.importc: "aowl_term_attr", nodecl.}
proc cTermRaw(on: int32) {.importc: "aowl_term_raw", nodecl.}
proc cTermKey(): int32 {.importc: "aowl_term_key", nodecl.}
proc cTermRestore() {.importc: "aowl_term_restore", nodecl.}
proc cTermSleep(ms: int32) {.importc: "aowl_term_sleep", nodecl.}
proc cTailRead(path: cstring; off, stamp, wasReset, buf: pointer;
               cap: int32): int32 {.importc: "aowl_tail_read", nodecl.}

# ---------------------------------------------------------------------------
# Capability
# ---------------------------------------------------------------------------

type
  TermMode* = enum
    tmPlain   ## not a console: redirected, piped, or no console at all
    tmColour  ## a console that would not take VT: colour, but no repainting
    tmFull    ## a console with VT: everything

var gMode = tmPlain
var gStarted = false
var gAscii = true

proc termStart*(): TermMode =
  ## Asked once. Everything else in here reads the answer.
  if not gStarted:
    gStarted = true
    let m = cTermInit()
    if m == 2'i32: gMode = tmFull
    elif m == 1'i32: gMode = tmColour
    else: gMode = tmPlain
    gAscii = cTermUtf8() == 0'i32
  result = gMode

proc termMode*(): TermMode =
  if not gStarted: discard termStart()
  result = gMode

proc termAscii*(): bool =
  ## True when the console would not go to UTF-8, so borders must be ASCII.
  if not gStarted: discard termStart()
  result = gAscii

proc forceAscii*() =
  ## `--ascii`. There is no way to detect a font with no box-drawing glyphs in
  ## it, and a player looking at a screen full of `?` needs a way out that is
  ## not "change your font".
  gAscii = true

proc forcePlain*() =
  ## `--plain`. The escape hatch for a terminal that reports VT and then does
  ## not honour it, which is a thing some multiplexers and remote shells do.
  discard termStart()
  gMode = tmPlain

proc stdinIsConsole*(): bool =
  if not gStarted: discard termStart()
  result = cTermStdinTty() != 0'i32

proc interrupted*(): bool =
  result = cTermInterrupted() != 0'i32

proc clearInterrupt*() =
  cTermClearInterrupt()

proc termRestore*() =
  cTermRestore()

proc sleepMs*(ms: int) =
  cTermSleep(int32(ms))

proc termSize*(w, h: var int) =
  ## 0x0 when there is no console. Callers treat that as "do not draw".
  w = int(cTermWidth())
  h = int(cTermHeight())

proc termWrite*(s: string) =
  ## Straight to the handle, past `syncio`'s buffer -- and the buffer is
  ## flushed first, because everything else in the launcher goes through `echo`
  ## and a frame written past a buffer holding half a heading appears *before*
  ## it. One ordering, kept in one place.
  if s.len == 0: return
  flushFile(stdout)
  var t = s
  cTermWrite(toCString(t), int32(t.len))

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

const
  KeyNone* = 0
  KeyEnter* = 13
  KeyEsc* = 27
  KeyUp* = 0x1026
  KeyDown* = 0x1028
  KeyLeft* = 0x1025
  KeyRight* = 0x1027
  KeyPageUp* = 0x1021
  KeyPageDown* = 0x1022
  KeyHome* = 0x1024
  KeyEnd* = 0x1023

proc rawMode*(on: bool) =
  cTermRaw(if on: 1'i32 else: 0'i32)

proc pollKey*(): int =
  ## 0 when nothing was typed. Never blocks.
  result = int(cTermKey())

proc drainKeys*() =
  while pollKey() != 0:
    discard

# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------
#
# Eight names rather than the full palette, because a colour that is only
# distinguishable on one theme is not information. These are the bright ANSI
# set, which is legible on both a white and a black background.

const
  ColDefault* = 0
  ColDim* = 1
  ColRed* = 2
  ColGreen* = 3
  ColYellow* = 4
  ColBlue* = 5
  ColMagenta* = 6
  ColCyan* = 7
  ColWhite* = 8

proc sgr(colour: int): string =
  case colour
  of ColDim: "\e[90m"
  of ColRed: "\e[91m"
  of ColGreen: "\e[92m"
  of ColYellow: "\e[93m"
  of ColBlue: "\e[94m"
  of ColMagenta: "\e[95m"
  of ColCyan: "\e[96m"
  of ColWhite: "\e[97m"
  else: "\e[0m"

proc consoleBits(colour: int): int32 =
  ## The `SetConsoleTextAttribute` equivalent, for the VT-less console.
  ## FOREGROUND_BLUE 1, GREEN 2, RED 4, INTENSITY 8.
  case colour
  of ColDim: 8'i32
  of ColRed: 12'i32
  of ColGreen: 10'i32
  of ColYellow: 14'i32
  of ColBlue: 11'i32
  of ColMagenta: 13'i32
  of ColCyan: 11'i32
  of ColWhite: 15'i32
  else: 7'i32

proc flushOut*() =
  ## For the paths that print through `aowlsptinstall/log`, which goes to
  ## `echo` and therefore to a buffer. Anything printed while something else is
  ## still happening has to be flushed, or it arrives after the thing it was
  ## describing.
  flushFile(stdout)

proc sayColoured*(colour: int; text: string) =
  ## One line, in colour where there is colour, and *only* the text where there
  ## is not. This is the plain-mode path, and it must never emit an escape.
  ##
  ## Flushed every time, and that is not belt and braces. `stdout` is fully
  ## buffered when it is a pipe or a file, so a redirected launcher streaming
  ## two logs writes **nothing** until four kilobytes have accumulated or the
  ## process exits -- and this is exactly the case where somebody is watching
  ## the file to find out why their game is stuck. A live view that only
  ## materialises on exit is not a live view.
  case termMode()
  of tmPlain:
    echo text
    flushFile(stdout)
  of tmColour:
    cTermAttr(consoleBits(colour))
    echo text
    flushFile(stdout)
    cTermAttr(consoleBits(ColDefault))
  of tmFull:
    echo sgr(colour) & text & "\e[0m"
    flushFile(stdout)

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

type
  Row* = object
    ## A line under construction. `width` is what the terminal will show;
    ## `text.len` is not, because of the escapes in it.
    text*: string
    width*: int

  Frame* = object
    ## A whole screen under construction, written in one call.
    text: string
    w*: int
    h*: int
    colour: bool

proc colsOf*(s: string): int =
  ## How many columns `s` occupies, which is **not** `s.len`.
  ##
  ## Box drawing is three bytes a glyph in UTF-8 and one column wide, and a
  ## message from a mod can carry any UTF-8 at all. A row padded by byte length
  ## puts its right-hand border three columns early for every box character in
  ## it, and the whole frame shears. Counting bytes that are not continuation
  ## bytes (`10xxxxxx`) is exact for everything this draws and one column out
  ## only for the double-width CJK ranges, which nothing here emits and a log
  ## line would have to go out of its way to contain.
  result = 0
  for ch in s:
    if (ord(ch) and 0xC0) != 0x80:
      inc result

proc newRow*(): Row =
  result = Row(text: "", width: 0)

proc put*(r: var Row; s: string) =
  r.text.add s
  r.width = r.width + colsOf(s)

proc putIn*(r: var Row; colour: int; s: string) =
  ## Coloured where colour exists, plain where it does not -- so one drawing
  ## routine serves the full terminal and the redirected file both.
  if termMode() == tmFull and colour != ColDefault:
    r.text.add sgr(colour)
    r.text.add s
    r.text.add "\e[0m"
  else:
    r.text.add s
  r.width = r.width + colsOf(s)

proc putRow*(r: var Row; other: Row) =
  ## One built row inside another. Not `put(r, other.text)`: that would count
  ## the colour escapes in `other.text` as columns, and every row containing a
  ## coloured cell would then be padded several columns short. The width comes
  ## from the row that already knows it.
  r.text.add other.text
  r.width = r.width + other.width

proc padTo*(r: var Row; n: int) =
  if r.width < n:
    let k = n - r.width
    r.text.add spaces(k)
    r.width = r.width + k

proc fit*(s: string; n: int): string =
  ## `s` cut to `n` **columns**, with the cut marked, and never cut through the
  ## middle of a UTF-8 sequence -- half a character reaches the console as a
  ## replacement glyph and takes the rest of the row's alignment with it.
  if n <= 0: return ""
  if colsOf(s) <= n: return s
  let want = (if n <= 1: n else: n - 1)
  var used = 0
  var i = 0
  while i < s.len:
    if (ord(s[i]) and 0xC0) != 0x80:
      if used == want: break
      inc used
    inc i
  result = s.substr(0, i - 1)
  if n > 1:
    result.add (if termAscii(): "~" else: "…")

# Borders. Two sets, chosen by whether the console took UTF-8.

proc bxH*(): string = (if termAscii(): "-" else: "─")
proc bxV*(): string = (if termAscii(): "|" else: "│")
proc bxTL*(): string = (if termAscii(): "+" else: "┌")
proc bxTR*(): string = (if termAscii(): "+" else: "┐")
proc bxBL*(): string = (if termAscii(): "+" else: "└")
proc bxBR*(): string = (if termAscii(): "+" else: "┘")
proc bxVL*(): string = (if termAscii(): "+" else: "├")
proc bxVR*(): string = (if termAscii(): "+" else: "┤")
proc bxTD*(): string = (if termAscii(): "+" else: "┬")
proc bxTU*(): string = (if termAscii(): "+" else: "┴")
proc bxCR*(): string = (if termAscii(): "+" else: "┼")

proc rule*(n: int): string =
  result = ""
  let h = bxH()
  for i in 0 ..< n:
    result.add h

proc bar*(filled, width: int): string =
  ## A progress bar of `width` cells, `filled` of them solid. Solid blocks in
  ## UTF-8, `#` and `.` otherwise -- both read as a bar in a monospaced font,
  ## which is the only thing a bar has to do.
  result = ""
  if width <= 0: return
  var f = filled
  if f < 0: f = 0
  if f > width: f = width
  let on = (if termAscii(): "#" else: "█")
  let off = (if termAscii(): "." else: "░")
  for i in 0 ..< width:
    if i < f: result.add on
    else: result.add off

# ---------------------------------------------------------------------------
# The alternate screen
# ---------------------------------------------------------------------------
#
# The log view takes the whole window and repaints it, which would otherwise
# eat the scrollback the preflight output is in. `?1049h` moves to the console's
# alternate buffer and `?1049l` puts the original back with its scrollback
# intact -- so on quit the player still has every line the launcher printed
# about their install, which is exactly what they will be asked to paste.

var gAltScreen = false
  ## Whether we are currently on the alternate buffer with the cursor hidden.
  ##
  ## Tracked rather than assumed, because "restore the terminal" is spread over
  ## six exit paths in `aowllaunch` (`q`, the quit confirmation, `d`, Ctrl+C,
  ## both processes gone, and the resize bail-out that hands over to
  ## `streamLogs`) and every one of them has to get it right. A program that
  ## exits with the console still on the alternate buffer, or still with the
  ## cursor hidden, has broken the shell the player ran it from -- which is a
  ## worse outcome than any frame it could have drawn. `termRestore` now closes
  ## over all of them at once, and calling `leaveFullScreen` twice is a no-op.

proc enterFullScreen*() =
  if termMode() != tmFull: return
  flushFile(stdout)
  gAltScreen = true
  termWrite("\e[?1049h\e[?25l\e[2J\e[H")

proc leaveFullScreen*() =
  if termMode() != tmFull: return
  if not gAltScreen: return
  gAltScreen = false
  termWrite("\e[?25h\e[?1049l\e[0m")

proc termShutdown*() =
  ## The ONE call every exit path can end on. Leaves the alternate buffer if we
  ## are on it, shows the cursor unconditionally (cheap, and the only way to be
  ## sure after a path that hid it without going full screen), resets attributes
  ## and restores the console mode. Safe to call when none of that applies.
  leaveFullScreen()
  if termMode() == tmFull: termWrite("\e[?25h\e[0m")
  cTermRestore()

# ---------------------------------------------------------------------------
# A block that repaints in place
# ---------------------------------------------------------------------------
#
# The boot progress is drawn here rather than on the alternate screen, and that
# is a deliberate difference from the log view.
#
# What the player is watching during boot is a handful of lines that keep
# changing, immediately under a preflight report they may well need to read
# again -- and the transcript of that report is the thing they will be asked to
# paste when something is wrong with their install. The alternate screen would
# take it away and give it back; repainting a block in place leaves it where it
# is, and leaves the finished progress block behind in the scrollback too, so
# what the launcher did during boot is still readable afterwards.
#
# It works by moving the cursor up over its own last paint, which means the
# block must fit in the window: a block taller than the console scrolls, the
# cursor arithmetic is then one line out per scrolled line, and the paint walks
# up the screen. `fitsInWindow` is what callers check before using one.

type
  Panel* = object
    lines: int

proc newPanel*(): Panel =
  result = Panel(lines: 0)

proc fitsInWindow*(rows: int): bool =
  if termMode() != tmFull: return false
  let h = int(cTermHeight())
  result = h > 0 and rows + 1 < h

proc paint*(p: var Panel; rows: seq[Row]) =
  ## No-op anywhere but a VT console: a redirected launcher that repainted
  ## would write the same block a hundred times into the file.
  if termMode() != tmFull: return
  var total = rows.len
  if p.lines > total: total = p.lines
  var s = ""
  if p.lines > 0:
    s.add "\e[" & $p.lines & "A"
  for i in 0 ..< total:
    s.add "\r"
    if i < rows.len: s.add rows[i].text
    s.add "\e[K\n"
  p.lines = total
  termWrite(s)

proc settle*(p: var Panel) =
  ## Leave the last paint where it is and stop tracking it, so ordinary output
  ## carries on beneath rather than over it.
  p.lines = 0

proc hideCursor*() =
  if termMode() == tmFull: termWrite("\e[?25l")

proc showCursor*() =
  if termMode() == tmFull: termWrite("\e[?25h")

proc newFrame*(w, h: int): Frame =
  ## Home the cursor and start collecting. `Frame`'s own fields are private
  ## because a caller has no business appending to the buffer directly: a row
  ## added without `addRow` is a row with no line-erase behind it, and it
  ## leaves the tail of the previous frame on screen.
  result = Frame(text: "\e[H", w: w, h: h, colour: termMode() == tmFull)

proc addRow*(f: var Frame; r: Row) =
  f.text.add r.text
  # Erase to the end of the line rather than padding with spaces: a frame that
  # pads is a frame whose width has to be exactly right, and a window resized
  # narrower between the size query and the write then wraps every row and
  # scrolls the screen by a frame's worth of lines.
  f.text.add "\e[K\r\n"

proc endFrame*(f: var Frame) =
  ## Everything below the last row cleared, then one write.
  f.text.add "\e[J"
  termWrite(f.text)

# ---------------------------------------------------------------------------
# Tailing a log
# ---------------------------------------------------------------------------

type
  Level* = enum
    lvPlain, lvOk, lvInfo, lvWarn, lvError

  LogLine* = object
    stamp*: string   ## `[1234ms]`, without the brackets, or "" when there is none
    level*: Level
    text*: string

  Tail* = object
    ## One log file, followed. See the C above for why this is by path.
    path*: string
    offset: int64
    stamp: int64
    started*: bool   ## true once the file has been seen at all
    lines*: seq[LogLine]
    partial: string
    dropped*: int    ## lines aged out of the scrollback
    cap*: int

proc newTail*(path: string; cap = 4000): Tail =
  result = Tail(path: path, offset: 0'i64, stamp: 0'i64, started: false,
                lines: @[], partial: "", dropped: 0, cap: cap)

proc levelOf*(l: Level): int =
  case l
  of lvOk: ColGreen
  of lvWarn: ColYellow
  of lvError: ColRed
  of lvInfo: ColDefault
  else: ColDim

proc levelName*(l: Level): string =
  case l
  of lvOk: "ok"
  of lvWarn: "warn"
  of lvError: "error"
  of lvInfo: "info"
  else: ""

proc parseLine*(raw: string): LogLine =
  ## `[1234ms] warn   the message` as the host writes it (`modhost.logLine`),
  ## and anything else -- the banner both logs open with, a stack trace, a line
  ## from a mod that wrote to the file itself -- kept whole and uncoloured
  ## rather than forced into the shape.
  result = LogLine(stamp: "", level: lvPlain, text: raw)
  if raw.len < 4 or raw[0] != '[': return
  let close = find(raw, "] ")
  if close < 0: return
  var rest = raw.substr(close + 2)
  result.stamp = raw.substr(1, close - 1)
  # The level is a five-character field followed by two spaces. Matched by
  # prefix rather than by splitting on whitespace, because the message itself
  # frequently begins with a word that would otherwise be eaten.
  if startsWith(rest, "ok   "): result.level = lvOk
  elif startsWith(rest, "info "): result.level = lvInfo
  elif startsWith(rest, "warn "): result.level = lvWarn
  elif startsWith(rest, "error"): result.level = lvError
  else:
    result.text = rest
    return
  result.text = strip(rest.substr(5), leading = true, trailing = false)

proc addLine(t: var Tail; raw: string) =
  var text = raw
  if t.lines.len == 0 and t.dropped == 0 and text.len >= 3 and
     ord(text[0]) == 0xEF and ord(text[1]) == 0xBB and ord(text[2]) == 0xBF:
    # A UTF-8 BOM on the first line. Neither host writes one, but a mod that
    # appends to the log with something that does would otherwise put three
    # invisible bytes in front of the banner -- which render as `ï»¿` on a
    # console that is not on codepage 65001, and read as a corrupt log.
    text = text.substr(3)
  if t.lines.len >= t.cap:
    # `seq` here has no `delete`, and a ring buffer with a head index would
    # make every reader do modular arithmetic to page through it. Rebuilding
    # once per `cap div 4` lines is cheaper than that is to get wrong.
    let keep = t.cap - (t.cap div 4)
    let drop = t.lines.len - keep
    var fresh: seq[LogLine] = @[]
    for i in drop ..< t.lines.len:
      fresh.add t.lines[i]
    t.lines = fresh
    t.dropped = t.dropped + drop
  t.lines.add parseLine(text)

proc pump*(t: var Tail): int =
  ## Whatever the writer has added since last time, as lines. Returns how many
  ## were added. A file that is not there yet is not an error: the backend has
  ## not started writing, and saying so is the caller's job.
  result = 0
  var buf = newSeq[byte](65536)
  while true:
    var off = t.offset
    var st = t.stamp
    var wasReset = 0'i32
    var p = t.path
    let n = cTailRead(toCString(p), addr off, addr st, addr wasReset,
                      cast[pointer](addr buf[0]), 65536'i32)
    t.offset = off
    t.stamp = st
    if n < 0'i32:
      return
    t.started = true
    if wasReset != 0'i32:
      t.lines = @[]
      t.partial = ""
      t.dropped = 0
    if n == 0'i32:
      return
    var chunk = ""
    let dest = beginStore(chunk, int(n))
    copyMem(dest, addr buf[0], int(n))
    endStore(chunk)
    for ch in chunk:
      if ch == '\n':
        var l = t.partial
        if l.len > 0 and l[l.len - 1] == '\r':
          l = l.substr(0, l.len - 2)
        t.addLine l
        t.partial = ""
        inc result
      else:
        t.partial.add ch
    if int(n) < 65536:
      return
