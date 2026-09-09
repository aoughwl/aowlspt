## Which mods are running on defaults because their `config.json` did not parse.
##
## ---------------------------------------------------------------------------
## Why this is the manager's job
## ---------------------------------------------------------------------------
##
## A host now answers `ErrConfigParse` for a config file that exists and is not
## readable JSON, and it says so once, in its own log, for the mod that asked.
## That is the right place for it and it is not enough on its own: the mod that
## was asked is the mod that already swallowed the status and carried on with
## its defaults, and the person who has to act on it is looking at a panel, not
## at a host log with fifty other lines in it.
##
## This manager is the only component that sees **every** loaded mod. It knows
## where each one's directory is, because it resolved the load order that put
## them there. So "three of your ten mods are running on defaults, and here is
## which three and what is wrong with each file" is a sentence only this mod can
## say, and nothing in this system said it before.
##
## ---------------------------------------------------------------------------
## One opinion about one file
## ---------------------------------------------------------------------------
##
## The check is the **host's own validator**, imported rather than
## reimplemented. That is the whole point of this module and it is worth being
## blunt about why: the manager used to carry a private structural check
## (`registry.wholeJsonObject`, a bracket counter) and used it on its own
## `config.json`. It was more lenient than the host's -- it accepted a trailing
## comma the host rejected -- so the two disagreed about the same bytes, and the
## manager's answer was the one that decided whether the manager trusted its own
## settings. Its own file is settled now by asking the host (`ConfigValue
## .faulted`); every *other* mod's file is settled here, by running the same
## code the host runs. A second opinion about a config file is not a safety net.
## It is the bug.
##
## The BOM is stripped before the check for exactly the same reason: the host
## reads config through a reader that drops one, so a BOM'd config is *not* a
## fault on the host, and a scan that called it one would be reporting a mod
## broken that is running fine.
##
## Nothing here reads a global, a clock or a socket, and the two decisions --
## "is this text a config a host can read" and "what is the sentence for a set
## of faults" -- are separate pure functions, so both can be driven from a test
## with no host, no registry and no files.

import std/syncio
import aowlspt/jsonpath

type
  ModConfigFault* = object
    ## One mod whose `config.json` is there and unreadable.
    id*: string
    path*: string
    fault*: string
      ## The host's own sentence: what is wrong and at which byte.

proc emptyConfigFault*(): ModConfigFault =
  ## Written out in full rather than left to default initialisation, for the
  ## same reason `writeguard.noFacts` is: a global in an `--app:lib` build that
  ## needs a call to initialise is left zeroed.
  result = ModConfigFault(id: "", path: "", fault: "")

proc stripConfigBom(text: string): string =
  ## A UTF-8 byte-order mark off the front, because the host's reader drops one
  ## before it validates. Kept private: this is not a general text utility, it
  ## is one half of "agree with the host".
  if text.len >= 3 and ord(text[0]) == 0xEF and ord(text[1]) == 0xBB and
     ord(text[2]) == 0xBF:
    return text.substr(3, text.len - 1)
  result = text

proc readConfigBytes*(path: string; into: var string): bool =
  ## The bytes of `path`, BOM dropped. **False means there is no such file**,
  ## which is not the same as an empty one -- a mod with no `config.json` runs
  ## on its defaults and that is a supported way to ship, while a zero-byte
  ## `config.json` is a half-finished write and is a fault. `registry
  ## .readTextFile` collapses those two into the empty string, which is fine
  ## for a registry that must exist and wrong here.
  into = ""
  var f: File
  try:
    if not open(f, path, fmRead):
      return false
  except:
    return false
  var got = ""
  var ok = false
  try:
    got = readAll(f)
    ok = true
  except:
    ok = false
  try:
    close(f)
  except:
    discard
  if not ok:
    return false
  into = stripConfigBom(got)
  result = true

proc configFaultIn*(text: string): string =
  ## "" when these bytes are a config file a host can read, and the host's own
  ## sentence -- naming the byte offset and what was found there -- when they
  ## are not.
  var why = ""
  if jsonFault(text, why):
    return why
  result = ""

proc configFaultAt*(dir, id: string; into: var ModConfigFault): bool =
  ## Whether `dir/config.json` exists and did not parse. `into` is only
  ## meaningful when this is true.
  into = emptyConfigFault()
  if dir.len == 0 or id.len == 0:
    return false
  let path = dir & "/config.json"
  var text = ""
  if not readConfigBytes(path, text):
    # No config.json at all. Ordinary, and silent on purpose.
    return false
  let fault = configFaultIn(text)
  if fault.len == 0:
    return false
  into = ModConfigFault(id: id, path: path, fault: fault)
  result = true

proc configFaultReport*(faults: seq[ModConfigFault]; loaded: int): string =
  ## The one line for the log, the panel's `problems` and the status route, or
  ## "" when every loaded mod's config was readable.
  ##
  ## It names the mods. A count on its own would be a fact nobody can act on --
  ## the whole failure this exists for is that the affected mod is *quiet*, so
  ## "three of them" without "which three" leaves the same search it was meant
  ## to end.
  if faults.len == 0:
    return ""
  var names = ""
  for f in faults:
    if names.len > 0: names.add ", "
    names.add f.id
  let verb = (if faults.len == 1: " is" else: " are")
  result = $faults.len & " of " & $loaded & " loaded mods" & verb &
           " running on defaults because their config.json did not parse: " &
           names & ". Every setting each of them believes it read is its own " &
           "default, and a mod that falls back to defaults on any failure -- " &
           "which is most of them -- will not say so itself"

proc configFaultDetail*(f: ModConfigFault): string =
  ## The per-mod line, for the log. One mod, its file and the fault in it.
  result = f.id & ": " & f.path & " -- " & f.fault
