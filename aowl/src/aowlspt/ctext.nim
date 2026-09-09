## ctext.nim -- getting TEXT out of C and into a nimony `string`, once.
##
## THE PROBLEM THIS EXISTS FOR
## ---------------------------
## Nimony has no `cstring` -> `string` conversion. Nim 2's `$cstring` is not
## available, and there is no `newString`+`copyMem` idiom that survives the
## bounds rules here. So every consumer of a C string coming out of the ABI --
## a region participant's name, a refusal reason, a capability id -- hand-rolled
## the SAME copy-into-a-caller-buffer C helper, privately. There were three such
## copies before this file; this is the shared one, so there is not a fourth.
##
## THE SHAPE, and why it is this shape
## -----------------------------------
## C never returns a `string`. What crosses the boundary is:
##
##   * a `cstring` the C side owns and keeps alive, plus
##   * a LENGTH obtained by a bounded scan on the C side.
##
## The Nim side then allocates once and fills byte by byte. That is slower than
## a `copyMem`, and it is deliberate: a `copyMem` from a pointer whose length
## came from the same untrusted side is exactly the read-past-the-end this is
## meant to prevent, and these strings are tens of bytes read at human speed,
## not a hot loop.
##
## EVERY READ IS BOUNDED. `cTextLen` scans at most `MaxCText` bytes and returns
## that cap if it finds no terminator, so an unterminated buffer costs a bounded
## read and yields a truncated string -- never a walk off the end of a page.
## A caller that needs to know truncation happened compares the result's length
## against `MaxCText`.
##
## NULL IS NOT AN ERROR CODE HERE. A nil pointer yields `""`, because every
## caller so far wants "no text" and not an exception, and a `""` that came from
## nil is indistinguishable from a `""` that came from an empty buffer -- which
## is correct: both mean the same thing to a label.

const
  MaxCText* = 4096
    ## The hard ceiling on any single C string read through this module.
    ## It is a REFUSAL, not a preference: an unterminated or corrupt buffer must
    ## cost a bounded read. Region names are 32 bytes and reasons are 192, so
    ## this is three orders of magnitude of headroom over any real caller.

{.emit: """
/* A bounded `strlen`. `strnlen` is not portable across the toolchains this
 * tree builds with, and `strlen` on a buffer that is not terminated is exactly
 * the unbounded read this module exists to prevent. */
static int32_t aowl_ctext_len(const char* s, int32_t cap) {
    int32_t n = 0;
    if (!s || cap <= 0) return 0;
    while (n < cap && s[n] != 0) n++;
    return n;
}
/* One byte, by index, with the bound re-checked on every call. The caller has
 * already been told the length; this does not trust it. */
static int32_t aowl_ctext_at(const char* s, int32_t i, int32_t cap) {
    if (!s || i < 0 || i >= cap) return 0;
    return (int32_t)(unsigned char)s[i];
}
""".}

proc cTextLenRaw(s: cstring; cap: int32): int32 {.
  importc: "aowl_ctext_len", nodecl.}
proc cTextAtRaw(s: cstring; i, cap: int32): int32 {.
  importc: "aowl_ctext_at", nodecl.}

proc cTextLen*(s: cstring): int =
  ## The length of a C string, scanning at most `MaxCText` bytes. A result equal
  ## to `MaxCText` means the terminator was NOT found within the cap -- treat it
  ## as truncated, not as an exact length.
  int(cTextLenRaw(s, int32(MaxCText)))

proc cText*(s: cstring): string =
  ## A C string as a nimony `string`, bounded by `MaxCText`.
  ##
  ## Returns `""` for a nil or empty pointer; those two are the same answer to
  ## every caller this has, and inventing a distinction neither one carries
  ## would be a lie dressed as precision.
  let n = cTextLen(s)
  if n <= 0:
    return ""
  var res = ""
  var i = 0
  while i < n:
    res.add char(cTextAtRaw(s, int32(i), int32(n)))
    inc i
  res

proc cTextOr*(s: cstring; dflt: string): string =
  ## `cText`, but with an explicit stand-in for "there was no text". Use this
  ## wherever an empty label on screen would read as a MEASUREMENT ("this
  ## participant has no name") rather than as an absence -- an empty string is
  ## the classic silently-wrong answer in this codebase.
  let t = cText(s)
  if t.len == 0: dflt else: t
