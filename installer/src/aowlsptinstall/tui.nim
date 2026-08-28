## Boxed output for the installer.
##
## This module is PURE. It takes a width, a glyph set and some strings, and it
## returns strings. It opens no console, queries no terminal and writes
## nothing, which is the only reason the layout can be tested at all -- and
## layout is exactly the kind of code that looks right in review and shears by
## three columns on a real console.
##
## The console questions -- is this a terminal, does it take VT, does it take
## UTF-8, how wide is it -- are asked once, by `aowlsptinstall.nim`, through
## `tools/aowlterm.nim`; the same library and the same detection the launcher
## uses. The answers arrive here as plain parameters.
##
## Two things it deliberately does not do:
##
## * **No alternate screen.** The launcher only goes full screen for its log
##   view. An installer's output is a transcript of what it did to a 40 GB game
##   directory, and that transcript is the thing a tester will be asked to
##   paste. The alternate buffer would take it away on exit.
## * **No box around unbounded content.** A file list is clipped to the box
##   width by `fitCols`, never wrapped -- a path broken across two bordered
##   lines is harder to read than a clipped one, and `--verbose` prints the
##   whole thing unboxed anyway.

import std/strutils

type
  Glyphs* = object
    ## Box drawing, in two flavours. Which one is in use is decided by whether
    ## the console took UTF-8, and that decision is made by the caller.
    h*, v*, tl*, tr*, bl*, br*, vl*, vr*: string

  BoxStyle* = enum
    bsPlain    ## an ordinary section
    bsGood     ## it worked
    bsBad      ## a refusal

const
  MinBoxWidth* = 40
  MaxBoxWidth* = 96
  DefaultBoxWidth* = 78

  SgrReset* = "\e[0m"
  SgrDim* = "\e[90m"
  SgrRed* = "\e[91m"
  SgrGreen* = "\e[92m"
  SgrYellow* = "\e[93m"
  SgrCyan* = "\e[96m"

proc asciiGlyphs*(): Glyphs =
  Glyphs(h: "-", v: "|", tl: "+", tr: "+", bl: "+", br: "+", vl: "+", vr: "+")

proc unicodeGlyphs*(): Glyphs =
  Glyphs(h: "─", v: "│", tl: "┌", tr: "┐",
         bl: "└", br: "┘", vl: "├", vr: "┤")

proc glyphsFor*(ascii: bool): Glyphs =
  if ascii: asciiGlyphs() else: unicodeGlyphs()

proc colsOf*(s: string): int =
  ## Columns, not bytes. A box glyph is three bytes and one column in UTF-8; a
  ## row padded by `len` puts its right border three columns early for every
  ## one of them and the whole frame shears. Continuation bytes (`10xxxxxx`)
  ## are not counted. Same rule as `aowlterm.colsOf`, restated here so this
  ## module stays free of the console layer.
  result = 0
  for ch in s:
    if (ord(ch) and 0xC0) != 0x80:
      inc result

proc fitCols*(s: string; n: int): string =
  ## `s` cut to `n` columns, marked, and never cut mid-sequence -- half a UTF-8
  ## character reaches the console as a replacement glyph and takes the rest of
  ## the row's alignment with it.
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
    result.add (if want == n: "" else: "~")

proc clampWidth*(w: int): int =
  ## A console narrower than `MinBoxWidth` gets `MinBoxWidth` and wraps, which
  ## is ugly; the caller is expected to fall back to plain output instead, and
  ## `boxUsable` is how it asks.
  if w < MinBoxWidth: return MinBoxWidth
  if w > MaxBoxWidth: return MaxBoxWidth
  result = w

proc boxUsable*(termWidth: int): bool =
  ## False for a console too narrow to draw in, and false for the 0 that
  ## `termSize` reports when there is no console at all. The caller degrades to
  ## plain lines. An installer that renders garbage is worse than a plain one.
  result = termWidth >= MinBoxWidth

proc rule*(g: Glyphs; n: int): string =
  result = ""
  for i in 0 ..< n:
    result.add g.h

proc styleSgr(style: BoxStyle): string =
  case style
  of bsGood: SgrGreen
  of bsBad: SgrRed
  else: SgrCyan

proc topLine*(g: Glyphs; title: string; width: int; style: BoxStyle;
              colour: bool): string =
  ## `+- Title ------------+`. The title is clipped, never allowed to push the
  ## right-hand corner off the end.
  let inner = width - 2
  var t = title
  if t.len > 0:
    t = " " & fitCols(t, inner - 5) & " "
  var s = g.tl & g.h
  var used = 2
  if t.len > 0:
    s.add t
    used = used + colsOf(t)
  if used < width - 1:
    s.add rule(g, width - 1 - used)
  s.add g.tr
  if colour:
    result = styleSgr(style) & s & SgrReset
  else:
    result = s

proc bottomLine*(g: Glyphs; width: int; style: BoxStyle;
                 colour: bool): string =
  var s = g.bl & rule(g, width - 2) & g.br
  if colour:
    result = styleSgr(style) & s & SgrReset
  else:
    result = s

proc tagColour(body: string): string =
  ## The tag column the installer's `log` module already emits, coloured. Keyed
  ## on the tag rather than on a parameter, so every path that prints an error
  ## gets the same colour without every call site having to say so.
  if body.startsWith("error"): return SgrRed
  if body.startsWith("warn"): return SgrYellow
  if body.startsWith("ok"): return SgrGreen
  if body.startsWith("would"): return SgrDim
  result = ""

proc bodyLine*(g: Glyphs; body: string; width: int; colour: bool): string =
  ## One content row, clipped and padded so the right border lands in the same
  ## column on every line of the box.
  let inner = width - 4
  let text = fitCols(body, inner)
  let pad = inner - colsOf(text)
  var painted = text
  if colour:
    let c = tagColour(body)
    if c.len > 0:
      painted = c & text & SgrReset
  var s = ""
  if colour:
    s.add SgrDim & g.v & SgrReset
  else:
    s.add g.v
  s.add " "
  s.add painted
  if pad > 0:
    s.add spaces(pad)
  s.add " "
  if colour:
    s.add SgrDim & g.v & SgrReset
  else:
    s.add g.v
  result = s

proc boxLines*(g: Glyphs; title: string; body: seq[string]; width: int;
               style: BoxStyle; colour: bool): seq[string] =
  ## A whole box. With `colour` off every line is exactly `width` columns wide,
  ## which is the property the tests assert -- with colour on the escapes are
  ## not columns and the assertion would be meaningless, so the tests measure
  ## the uncoloured form and the colour is a pure prefix/suffix on top of it.
  result = @[]
  result.add topLine(g, title, width, style, colour)
  for b in body:
    result.add bodyLine(g, b, width, colour)
  result.add bottomLine(g, width, style, colour)

proc bar*(filled, width: int; ascii: bool): string =
  ## A progress bar, same shape as `aowlterm.bar`.
  result = ""
  if width <= 0: return
  var f = filled
  if f < 0: f = 0
  if f > width: f = width
  let on = (if ascii: "#" else: "█")
  let off = (if ascii: "." else: "░")
  for i in 0 ..< width:
    if i < f: result.add on
    else: result.add off

proc progressLine*(done, total, width: int; ascii: bool): string =
  ## `[####....]  37 / 120`. `total` of zero means "no denominator known", and
  ## it prints a count rather than a bar that would otherwise sit at zero or at
  ## full and mean neither.
  if total <= 0:
    return "  " & $done & " files"
  var cells = width
  if cells < 8: cells = 8
  let filled = (done * cells) div (if total > 0: total else: 1)
  result = "[" & bar(filled, cells, ascii) & "]  " & $done & " / " & $total
