## aowlspt/args — a mod declares the command-line arguments it understands, and
## reads them.
##
## The problem this solves. Before the menu exists, before `config.json` has
## been read for the first time, before any UI a player could click, the ONLY
## channel into the client is the process command line — and until now nothing
## in the host, the ABI or this library mentioned it. A mod that wanted an
## argument had to emit its own C, call `GetCommandLineW` and write its own
## parser, and every mod that did would have parsed it differently.
##
## The wire format is fixed and belongs to the host:
##
##     -aowl.<name>=<value>       a value
##     -aowl.<name>               a bare flag; its value is the string "true"
##     -aowl.<name>="two words"   a quoted value (the quotes are not part of it)
##
## The launcher writes these for you: any option `aowlspt-launch` does not know
## is forwarded, so `aowlspt-launch --raid=Woods` puts `-aowl.raid=Woods` on the
## game's line and says so.
##
##     import aowlspt/args
##
##     proc onLoad(): Status =
##       declareArgs(@[
##         argSpec("raid", "Enter this map's raid on launch, no clicks",
##                 default = "", kind = akString, example = "-aowl.raid=Woods"),
##         argSpec("raiddebug", "Log every step of raid entry",
##                 default = "false", kind = akBool)])
##       if hasCmdArg("raid"):
##         info "autoraid: -aowl.raid=\"" & cmdArg("raid") & "\""
##       result = Ok
##
## READING DOES NOT REQUIRE DECLARING. `cmdArg` answers from the host's parsed
## table whether or not anything declared the name. Declaring is what makes the
## host able to AUDIT: it prints one boot line naming every declared argument
## with its value or `absent (default X)`, and it warns about every `-aowl.*`
## token on the line that NO loaded mod claimed — so a typo announces itself
## instead of silently doing nothing. That warning is the whole reason to
## declare, and it is a check that can fail, which is the point.
##
## THREADS AND COST. The host parses the line once, during its own startup, and
## the table is immutable afterwards; a read is a copy. This module fetches the
## whole table on FIRST use and caches it, so the second and every later
## `cmdArg` is a local lookup with no host call at all. The cache is filled by
## whichever thread asks first; if two threads race, both build the same table
## from the same frozen source and the loser's copy is discarded — the values
## cannot differ.

import ".." / aowlspt            # call, Status, Ok, info, warn

type
  ArgKind* = enum
    akString = "string"
    akBool = "bool"
    akInt = "int"

  ArgSpec* = object
    name*: string          ## without the `-aowl.` prefix: "raid"
    description*: string   ## one line, for the boot audit and for --help
    default*: string       ## as TEXT, what the mod uses when it is absent
    kind*: ArgKind
    example*: string       ## e.g. `-aowl.raid="Ground Zero"`

proc argSpec*(name: string; description: string; default = "";
              kind = akString; example = ""): ArgSpec =
  ArgSpec(name: name, description: description, default: default,
          kind: kind, example: example)

var gArgNames: seq[string] = @[]
var gArgVals: seq[string] = @[]
var gArgRaw = ""
var gArgLoaded = false
var gArgHostOk = false
var gArgDeclared = false

proc argJsonEsc(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c == '"': result.add "\\\""
    elif c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\r': result.add "\\r"
    elif c == '\t': result.add "\\t"
    else: result.add c

proc argLower(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z': result.add chr(ord(c) + 32)
    else: result.add c

proc argParseTable(js: string) =
  ## Pull `"args":{"a":"1","b":"2"}` out of the host's reply. A hand parser and
  ## not the JSON module, because this runs on `onLoad` before anything else is
  ## set up and the shape is fixed and small. Every value the host emits is
  ## escaped by `caEsc` on that side, so the only escapes possible here are the
  ## ones undone below.
  var names: seq[string] = @[]
  var vals: seq[string] = @[]
  var raw = ""
  # ---- raw
  block:
    let k = "\"raw\":\""
    var at = -1
    var i = 0
    while i + k.len <= js.len:
      var m = true
      for t in 0 ..< k.len:
        if js[i + t] != k[t]: m = false
      if m:
        at = i + k.len
        break
      i = i + 1
    if at >= 0:
      var i2 = at
      while i2 < js.len and js[i2] != '"':
        if js[i2] == '\\' and i2 + 1 < js.len:
          i2 = i2 + 1
          let e = js[i2]
          if e == 'n': raw.add '\n'
          elif e == 't': raw.add '\t'
          elif e == 'r': raw.add '\r'
          else: raw.add e
        else:
          raw.add js[i2]
        i2 = i2 + 1
  # ---- the args object
  block:
    let k = "\"args\":{"
    var at = -1
    var i = 0
    while i + k.len <= js.len:
      var m = true
      for t in 0 ..< k.len:
        if js[i + t] != k[t]: m = false
      if m:
        at = i + k.len
        break
      i = i + 1
    if at < 0: return
    var i2 = at
    var cur = ""
    var inStr = false
    var haveName = false
    var name = ""
    while i2 < js.len:
      let c = js[i2]
      if inStr:
        if c == '\\' and i2 + 1 < js.len:
          i2 = i2 + 1
          let e = js[i2]
          if e == 'n': cur.add '\n'
          elif e == 't': cur.add '\t'
          elif e == 'r': cur.add '\r'
          else: cur.add e
        elif c == '"':
          inStr = false
          if haveName:
            names.add name
            vals.add cur
            haveName = false
          else:
            name = cur
            haveName = true
          cur = ""
        else:
          cur.add c
      else:
        if c == '"':
          inStr = true
          cur = ""
        elif c == '}':
          break
      i2 = i2 + 1
  gArgNames = names
  gArgVals = vals
  gArgRaw = raw

proc argsEnsure() =
  if gArgLoaded: return
  gArgLoaded = true
  var reply = ""
  if call("aowlspt.host::cmdline", "", reply) == Ok and reply.len > 0:
    gArgHostOk = true
    argParseTable(reply)
  else:
    # NOT "there are no arguments". The host did not answer, which is a
    # different fact and has to read as one: every `cmdArg` below will return
    # its default and `cmdlineAvailable()` says false so a mod can report
    # INCONCLUSIVE instead of asserting absence.
    warn "args: the host did not answer aowlspt.host::cmdline, so NO " &
         "command-line argument can be read this session. Every cmdArg() " &
         "returns its default; this is a refusal, not an empty command line."

proc cmdlineAvailable*(): bool =
  ## False means "I could not look", never "no arguments were given".
  argsEnsure()
  gArgHostOk

proc cmdlineRaw*(): string =
  ## The raw process command line as the host saw it, for a mod that wants to
  ## say what it looked at when an argument is missing.
  argsEnsure()
  gArgRaw

proc hasCmdArg*(name: string): bool =
  ## Case-insensitive, exactly as the host matches.
  argsEnsure()
  let want = argLower(name)
  var i = 0
  while i < gArgNames.len:
    if argLower(gArgNames[i]) == want: return true
    i = i + 1
  result = false

proc cmdArg*(name: string; default = ""): string =
  argsEnsure()
  let want = argLower(name)
  var i = 0
  while i < gArgNames.len:
    if argLower(gArgNames[i]) == want: return gArgVals[i]
    i = i + 1
  result = default

proc cmdArgBool*(name: string; default = false): bool =
  ## A BARE `-aowl.<name>` is "true"; so are `1`, `yes` and `on`. Anything else
  ## present but unrecognised returns the DEFAULT and warns — a value the mod
  ## cannot read must not silently become `false`.
  if not hasCmdArg(name): return default
  let v = argLower(cmdArg(name))
  if v == "true" or v == "1" or v == "yes" or v == "on": return true
  if v == "false" or v == "0" or v == "no" or v == "off": return false
  warn "args: -aowl." & name & "=\"" & cmdArg(name) & "\" is not a boolean; " &
       "using the default (" & (if default: "true" else: "false") & ")"
  result = default

proc cmdArgInt*(name: string; default = 0): int =
  ## Same rule: an unparseable value returns the default AND says so.
  if not hasCmdArg(name): return default
  let v = cmdArg(name)
  var acc = 0
  var neg = false
  var any = false
  var i = 0
  if i < v.len and (v[i] == '-' or v[i] == '+'):
    neg = v[i] == '-'
    i = i + 1
  while i < v.len:
    let c = v[i]
    if c < '0' or c > '9':
      warn "args: -aowl." & name & "=\"" & v & "\" is not an integer; using " &
           "the default (" & $default & ")"
      return default
    acc = acc * 10 + (ord(c) - ord('0'))
    any = true
    i = i + 1
  if not any:
    warn "args: -aowl." & name & " has an empty value; using the default (" &
         $default & ")"
    return default
  result = if neg: -acc else: acc

proc declareArgs*(specs: seq[ArgSpec]; modId = "") =
  ## Register this mod's arguments with the host's boot AUDIT. Call it ONCE,
  ## from `onLoad`, with the whole list.
  ##
  ## It does not gate reading and it cannot fail the mod: the worst case is
  ## that the host is not there, which is reported and nothing else. A second
  ## call is refused rather than doubling the audit line, for the same reason
  ## `declareSettings` refuses one.
  if gArgDeclared:
    warn "args: declareArgs called twice; the second call was REFUSED and " &
         "nothing was re-declared. Declare the whole list once, in onLoad."
    return
  gArgDeclared = true
  argsEnsure()
  var body = "{\"mod\":\"" & argJsonEsc(if modId.len > 0: modId else: modName()) &
             "\",\"args\":["
  var i = 0
  while i < specs.len:
    if i > 0: body.add ","
    body.add "{\"name\":\"" & argJsonEsc(specs[i].name) &
             "\",\"description\":\"" & argJsonEsc(specs[i].description) &
             "\",\"default\":\"" & argJsonEsc(specs[i].default) &
             "\",\"kind\":\"" & $specs[i].kind &
             "\",\"example\":\"" & argJsonEsc(specs[i].example) & "\"}"
    i = i + 1
  body.add "]}"
  var reply = ""
  if call("aowlspt.host::args_declare", body, reply) != Ok:
    warn "args: the host refused aowlspt.host::args_declare, so this mod's " &
         "arguments will be reported as UNDECLARED in the boot audit even " &
         "though it reads them. The reads themselves are unaffected."
