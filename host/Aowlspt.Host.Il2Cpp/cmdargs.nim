# ---------------------------------------------------------------------------
# cmdargs.nim -- MOD-REGISTERED COMMAND-LINE ARGUMENTS.
#
# WHAT THIS IS. The game's own command line is the only channel that exists
# before a single mod has loaded, before any settings file is read and before
# the menu is up. Until now nothing in host/, abi/, aowl/ or mods/ so much as
# mentioned `GetCommandLine`: a mod that wanted an argument had to emit its own
# C and parse the line itself, and every mod that did would parse it
# differently. This parses it ONCE, at startup, on the host thread, into an
# immutable name->value table, and hands it to every mod through one verb.
#
# THE WIRE FORMAT, fixed:
#     -aowl.<name>=<value>      a value
#     -aowl.<name>              a bare flag; the value is the string "true"
#     -aowl.<name>="two words"  a quoted value (the quotes are NOT part of it)
# Anything on the line that is not `-aowl.` prefixed is ignored here; the game
# and Unity own the rest of it.
#
# WHY GetCommandLineA AND NOT CommandLineToArgvW. `CommandLineToArgvW` lives in
# shell32 and would add a link-time dependency to the host DLL for a job that
# is one quote-aware split. The ANSI line is what the launcher writes and every
# token we care about is ASCII by construction (a map LABEL is matched against
# TMP text elsewhere, not here). A non-ASCII byte survives the copy verbatim
# and is reported verbatim; it is simply never equal to a declared name.
#
# THREADING. `caParseOnce` runs during host init, on the host thread, before any
# mod is loaded and before the drain exists. Everything after that only READS
# the table -- and a read of a Nim string/seq global is a COPY, allocated on
# the reading thread, so a mod calling `aowlspt.host::cmdline` from its ops
# thread never frees a buffer this side owns. Nothing reassigns these globals
# after the parse; that is the invariant that makes the reads safe, and
# `caParseOnce` refuses to run twice rather than trusting itself.
#
# FAIL CLOSED. A `-aowl.*` token that NO mod declared is a TYPO, and a typo
# that is silently ignored is the worst outcome this file can produce -- the
# player sees no raid, no error, and no reason. `caSweepTick` warns about every
# undeclared token exactly once, after a grace period long enough for the mods
# to have loaded and declared, and names them.
# ---------------------------------------------------------------------------

{.emit: """
/* The raw process command line, snapshotted ONCE into a bounded buffer of our
 * own. ANSI on purpose -- see the banner. Two accessors rather than handing a
 * `const char*` to Nim, because a bounded byte-at-a-time read on this side is
 * the same code either way and this one cannot run off the end. */
#define AOWL_CA_CAP 4096
static char aowl_ca_buf[AOWL_CA_CAP];
static int32_t aowl_ca_n = -1;
static int32_t aowl_ca_snap(void) {
    if (aowl_ca_n >= 0) return aowl_ca_n;
    const char* s = GetCommandLineA();
    int32_t i = 0;
    if (s) { while (i < AOWL_CA_CAP - 1 && s[i]) { aowl_ca_buf[i] = s[i]; i++; } }
    aowl_ca_buf[i] = 0;
    aowl_ca_n = i;
    return aowl_ca_n;
}
static int32_t aowl_ca_len(void) { return aowl_ca_snap(); }
static int32_t aowl_ca_byte(int32_t i) {
    if (i < 0 || i >= aowl_ca_snap()) return 0;
    return (int32_t)(unsigned char)aowl_ca_buf[i];
}
static int32_t aowl_ca_cap(void) { return AOWL_CA_CAP - 1; }
""".}

proc cCaLen(): int32 {.importc: "aowl_ca_len", nodecl.}
proc cCaByte(i: int32): int32 {.importc: "aowl_ca_byte", nodecl.}
proc cCaCap(): int32 {.importc: "aowl_ca_cap", nodecl.}

const
  CaPrefix = "-aowl."
  CaMaxRaw = 4096      ## bounded copy of the raw line (rule 4: capped)
  CaMaxArgs = 64       ## most `-aowl.*` tokens we will hold
  CaMaxName = 64
  CaMaxValue = 256
  CaMaxDeclared = 256
  CaSweepFrames = 3600
    ## Frames of the per-frame drain before the undeclared-token sweep runs.
    ## FRAMES and not milliseconds on purpose: this file is included long
    ## before the host's clock helpers are in scope, and a frame count is a
    ## measurement of the thing that actually gates mod loading. At 60 fps this
    ## is ~60 s; a mod that declares later still gets its own audit line, the
    ## sweep is simply the backstop that names orphans.

var gCaRaw = ""                    ## the raw line, bounded, verbatim
var gCaNames: seq[string] = @[]    ## parsed `aowl.*` names, in line order
var gCaVals: seq[string] = @[]     ## parallel values ("true" for a bare flag)
var gCaParsed = false              ## the parse ran (once)
var gCaTrunc = false               ## the raw line hit CaMaxRaw
var gCaOver = 0                    ## tokens dropped at CaMaxArgs

var gCaDeclNames: seq[string] = @[]  ## every arg any mod declared
var gCaDeclOwner: seq[string] = @[]  ## which mod declared it
var gCaDeclCalls = 0
var gCaFrames = 0
var gCaSwept = false

proc caEsc(s: string): string =
  ## Minimal JSON escaping. The raw command line contains backslashes and
  ## quotes by construction, so an unescaped copy would hand every consumer a
  ## payload that does not parse -- which reads as "no arguments" for entirely
  ## the wrong reason.
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c == '"': result = result & "\\\""
    elif c == '\\': result = result & "\\\\"
    elif c == '\n': result = result & "\\n"
    elif c == '\r': result = result & "\\r"
    elif c == '\t': result = result & "\\t"
    elif ord(c) < 0x20: result = result & " "
    else: result = result & c

proc caLower(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result = result & chr(ord(c) + 32)
    else: result = result & c

proc caHas(name: string): bool =
  ## Names are matched CASE-INSENSITIVELY: `-aowl.Raid` and `-aowl.raid` are
  ## the same argument. A case-sensitive match here would be a silent no-op the
  ## first time somebody capitalised a name, which is the failure mode this
  ## whole file exists to prevent.
  let want = caLower(name)
  var i = 0
  while i < gCaNames.len:
    if caLower(gCaNames[i]) == want: return true
    i = i + 1
  result = false

proc caGet(name: string): string =
  let want = caLower(name)
  var i = 0
  while i < gCaNames.len:
    if caLower(gCaNames[i]) == want: return gCaVals[i]
    i = i + 1
  result = ""

proc caAdd(name, value: string) =
  if gCaNames.len >= CaMaxArgs:
    gCaOver = gCaOver + 1
    return
  var n = name
  var v = value
  if n.len > CaMaxName: n = n.substr(0, CaMaxName - 1)
  if v.len > CaMaxValue: v = v.substr(0, CaMaxValue - 1)
  # LAST WINS, and it says so: two of the same token on one line is a mistake
  # worth naming, not a coin flip.
  var i = 0
  while i < gCaNames.len:
    if caLower(gCaNames[i]) == caLower(n):
      warn "cmdline: -aowl." & n & " appears more than once; the LAST value " &
           "wins (\"" & gCaVals[i] & "\" -> \"" & v & "\")"
      gCaVals[i] = v
      return
    i = i + 1
  gCaNames.add n
  gCaVals.add v

proc caSplitAdd(tok: string) =
  ## One already-unquoted token. `-aowl.name=value` or `-aowl.name`.
  if tok.len <= CaPrefix.len: return
  var isPrefix = true
  for i in 0 ..< CaPrefix.len:
    if tok[i] != CaPrefix[i]: isPrefix = false
  if not isPrefix: return
  var eq = -1
  var i = CaPrefix.len
  while i < tok.len:
    if tok[i] == '=':
      eq = i
      break
    i = i + 1
  if eq < 0:
    caAdd(tok.substr(CaPrefix.len, tok.len - 1), "true")
  else:
    let n = tok.substr(CaPrefix.len, eq - 1)
    if n.len == 0: return
    caAdd(n, tok.substr(eq + 1, tok.len - 1))

proc caParseLine(line: string) =
  ## A quote-aware split. Quotes are STRIPPED wherever they appear inside a
  ## token, so all three of `-aowl.raid="Ground Zero"`, `-aowl.raid=Ground Zero`
  ## (already one token because the launcher quoted the whole thing) and
  ## `"-aowl.raid=Ground Zero"` yield the value `Ground Zero`. This is the same
  ## rule the C runtime applies to argv, minus the backslash-escape case, which
  ## a value on this wire has no use for -- and which is stated here rather
  ## than silently mishandled.
  var tok = ""
  var inQ = false
  var i = 0
  while i < line.len:
    let c = line[i]
    if c == '"':
      inQ = not inQ
    elif (c == ' ' or c == '\t') and not inQ:
      if tok.len > 0:
        caSplitAdd(tok)
        tok = ""
    else:
      tok = tok & c
    i = i + 1
  if tok.len > 0: caSplitAdd(tok)

proc caParseOnce() =
  ## Host init calls this exactly once, before any mod exists. Refuses a second
  ## call rather than rebuilding the table under a reader.
  if gCaParsed:
    warn "cmdline: caParseOnce called twice; the table is IMMUTABLE after the " &
         "first parse and the second call did nothing. Readers were not " &
         "disturbed, but this is a bug in the caller."
    return
  gCaParsed = true
  var raw = ""
  let n = int(cCaLen())
  var i = 0
  while i < n and i < CaMaxRaw:
    raw = raw & chr(int(cCaByte(int32(i))))
    i = i + 1
  if n >= int(cCaCap()): gCaTrunc = true
  gCaRaw = raw
  caParseLine(raw)
  info "cmdline: raw = " & (if raw.len > 0: raw else: "(empty)") &
       (if gCaTrunc: "  [TRUNCATED at " & $CaMaxRaw & " chars]" else: "")
  if gCaNames.len == 0:
    info "cmdline: no -aowl.* arguments on the line"
  else:
    var s = ""
    var i = 0
    while i < gCaNames.len:
      if i > 0: s = s & ", "
      s = s & "aowl." & gCaNames[i] & "=\"" & gCaVals[i] & "\""
      i = i + 1
    info "cmdline: parsed " & $gCaNames.len & " -aowl.* argument(s): " & s
  if gCaOver > 0:
    warn "cmdline: " & $gCaOver & " -aowl.* token(s) past the cap of " &
         $CaMaxArgs & " were DROPPED and are not readable by any mod"

proc caCmdlineJson(): string =
  ## `call("aowlspt.host::cmdline", "")`. The whole table, plus the raw line so
  ## a mod can say what it saw when a name is absent.
  var argsJson = ""
  var i = 0
  while i < gCaNames.len:
    if i > 0: argsJson = argsJson & ","
    argsJson = argsJson & "\"" & caEsc(gCaNames[i]) & "\":\"" &
               caEsc(gCaVals[i]) & "\""
    i = i + 1
  result = "{\"parsed\":" & (if gCaParsed: "true" else: "false") &
           ",\"raw\":\"" & caEsc(gCaRaw) & "\"" &
           ",\"count\":" & $gCaNames.len &
           ",\"truncated\":" & (if gCaTrunc: "true" else: "false") &
           ",\"dropped\":" & $gCaOver &
           ",\"args\":{" & argsJson & "}}"

# ---- the declaration audit ------------------------------------------------

proc caJsonStr(src: string; key: string; start: int; stop: int): string =
  ## The value of `"key":"..."` between `start` and `stop`. A hand parser, not
  ## `jsonpath`, because this runs during boot on a payload a mod wrote and the
  ## shape is fixed; it returns "" for anything it cannot read and every caller
  ## treats "" as ABSENT rather than as an empty declaration.
  let pat = "\"" & key & "\""
  var i = start
  var at = -1
  while i + pat.len <= stop:
    var m = true
    for k in 0 ..< pat.len:
      if src[i + k] != pat[k]: m = false
    if m:
      at = i
      break
    i = i + 1
  if at < 0: return ""
  var j = at + pat.len
  while j < stop and (src[j] == ' ' or src[j] == ':'): j = j + 1
  if j >= stop or src[j] != '"': return ""
  j = j + 1
  var outp = ""
  var n = 0
  while j < stop and src[j] != '"' and n < CaMaxValue:
    if src[j] == '\\' and j + 1 < stop: j = j + 1
    outp = outp & src[j]
    j = j + 1
    n = n + 1
  result = outp

proc caDeclareJson(argText: string): string =
  ## `call("aowlspt.host::args_declare", json)`.
  ##
  ## Payload: `{"mod":"aowl.autoraid","args":[{"name":"raid",
  ##            "description":"..","default":"..","kind":"string",
  ##            "example":"-aowl.raid=Woods"}]}`
  ##
  ## What it is FOR: the audit line. Declaring an argument does not make it
  ## readable -- `cmdArg` reads the parsed table whether anything declared it
  ## or not -- it makes the host able to say, in the boot log, WHICH arguments
  ## a build understands and which of them were actually given. Without that,
  ## the only evidence a mod's argument exists is the mod's own source.
  gCaDeclCalls = gCaDeclCalls + 1
  let owner0 = caJsonStr(argText, "mod", 0, argText.len)
  let owner = if owner0.len > 0: owner0 else: "(unnamed mod)"
  var declared = 0
  var lines = ""
  # Each object is located by its own "name" key; the fields of that object are
  # read between this "name" and the next one. A mod that emits a different
  # order still works; a mod that omits "name" contributes nothing and is
  # counted as such.
  var positions: seq[int] = @[]
  var i = 0
  let pat = "\"name\""
  while i + pat.len <= argText.len:
    var m = true
    for k in 0 ..< pat.len:
      if argText[i + k] != pat[k]: m = false
    if m:
      positions.add i
      i = i + pat.len
    else:
      i = i + 1
    if positions.len >= CaMaxDeclared: break
  var pi = 0
  while pi < positions.len:
    let a = positions[pi]
    let b = if pi + 1 < positions.len: positions[pi + 1] else: argText.len
    let nm = caJsonStr(argText, "name", a, b)
    if nm.len > 0:
      let dflt = caJsonStr(argText, "default", a, b)
      let kind = caJsonStr(argText, "kind", a, b)
      if gCaDeclNames.len < CaMaxDeclared:
        gCaDeclNames.add nm
        gCaDeclOwner.add owner
      declared = declared + 1
      if lines.len > 0: lines = lines & "; "
      lines = lines & "-aowl." & nm &
              (if kind.len > 0: " (" & kind & ")" else: "") & " = " &
              (if caHas(nm): "\"" & caGet(nm) & "\""
               else: "absent (default " &
                     (if dflt.len > 0: "\"" & dflt & "\"" else: "none") & ")")
    pi = pi + 1
  if declared == 0:
    warn "cmdline: " & owner & " called args_declare with a payload holding " &
         "no readable \"name\" field. NOTHING was declared, so every -aowl.* " &
         "token it meant to claim will be reported as UNDECLARED by the " &
         "sweep. This is a refusal, not a silent skip."
  else:
    info "cmdline: " & owner & " declares " & $declared & " argument(s): " &
         lines
  result = "{\"ok\":" & (if declared > 0: "true" else: "false") &
           ",\"mod\":\"" & caEsc(owner) & "\"" &
           ",\"declared\":" & $declared &
           ",\"knownTotal\":" & $gCaDeclNames.len &
           ",\"present\":" & $gCaNames.len & "}"

proc caDeclaredBy(name: string): string =
  let want = caLower(name)
  var i = 0
  while i < gCaDeclNames.len:
    if caLower(gCaDeclNames[i]) == want: return gCaDeclOwner[i]
    i = i + 1
  result = ""

proc caSweepTick() =
  ## Ridden on the per-frame drain. Costs one integer compare on every frame
  ## except the single one it fires on, and nothing at all afterwards.
  ##
  ## THE CHECK IS A NEGATIVE, deliberately: "no -aowl.* token on this line is
  ## unclaimed". That can fail -- misspell one and it fires. A positive check
  ## ("every declared arg was seen") could not: an absent optional argument is
  ## the normal case.
  if gCaSwept: return
  gCaFrames = gCaFrames + 1
  if gCaFrames < CaSweepFrames: return
  gCaSwept = true
  if gCaNames.len == 0: return
  var orphans = ""
  var n = 0
  var i = 0
  while i < gCaNames.len:
    if caDeclaredBy(gCaNames[i]).len == 0:
      if orphans.len > 0: orphans = orphans & ", "
      orphans = orphans & "-aowl." & gCaNames[i] & "=\"" & gCaVals[i] & "\""
      n = n + 1
    i = i + 1
  if n == 0:
    info "cmdline: AUDIT PASS -- every -aowl.* argument on the line (" &
         $gCaNames.len & ") was declared by a loaded mod"
  else:
    warn "cmdline: AUDIT -- " & $n & " of " & $gCaNames.len & " -aowl.* " &
         "argument(s) were declared by NO loaded mod and are being IGNORED: " &
         orphans & ". Either the name is misspelled, or the mod that owns it " &
         "is not loaded, or it declares its arguments later than " &
         $CaSweepFrames & " drain frames (in which case its own " &
         "`declares N argument(s)` line above is the authority and this " &
         "warning is a false alarm -- say so rather than chasing it)."
