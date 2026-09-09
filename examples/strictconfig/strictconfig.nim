## Config that refuses instead of defaulting.
##
##     aowl build-mod examples/strictconfig
##     aowl run examples/strictconfig
##
##     :: and the case the whole file is about — the same mod, one directory
##     :: over, with a config.json that does not parse
##     mkdir installer\build\strictconfig-broken
##     copy examples\strictconfig\bin\strictconfig.dll installer\build\strictconfig-broken
##     copy examples\strictconfig\broken-config.json ^
##          installer\build\strictconfig-broken\config.json
##     host\Aowlspt.Sim\bin\aowlspt-sim.exe installer\build\strictconfig-broken ^
##         --side sim --ticks 3
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## `configGet` has **three** answers and every example in this directory reads
## it as though it had two.
##
##   `Ok`               there is a config file, it parses, here is the value.
##   `ErrNotFound`      there is no config file, or no such key in it.
##   `ErrConfigParse`   the config file is **there** and does not parse.
##
## The third is the one the status code exists for, and the library says what to
## do with it: *do not carry on quietly*. What every config-reading example does
## instead is collapse all three into "no config, use the default":
##
##     examples/gameserver:101   setting("weightMultiplier").asFloat(1.0)
##     examples/backend:77-79    configGet(...) != Ok -> "no weightMultiplier
##                               configured, using <default>"
##     examples/lesson:242-243   configGet("", whole) != Ok -> "no config.json
##                               here, so the built-in defaults stand"
##
## The last one is the file people copy from, and it is the clearest case: it
## asks for the **whole document**, which is precisely the call that can come
## back `ErrConfigParse` with the broken bytes attached, and reports it as a
## file that is not there.
##
## One line each. The honest version is four:
##
##     if configFaulted():
##       error "config.json is present and does not parse: " & lastError()
##       return                       # and nothing below runs
##     weightMultiplier = setting("weightMultiplier").asFloat(1.0)
##
## That ratio is the actual problem with this API and this example does not
## hide it: the wrong answer is shorter, reads fine, compiles, and produces a
## mod that runs. It just runs on settings nobody chose.
##
## ---------------------------------------------------------------------------
## A DEFAULT IS SOMETIMES A DECISION
## ---------------------------------------------------------------------------
##
## Not every mod should refuse. The distinction, which `aowlspt/server` draws
## above `ConfigValue.faulted` and `mods/pathtotarkov` acts on:
##
##   * A default that is a **fallback** — a tick interval, a log verbosity, a
##     cache size — is fine to fall back to. Nobody is harmed by 300 instead of
##     600.
##   * A default that is a **decision** — a load order, an enabled set, a list
##     of maps, a starting location — is not a fallback at all. It is this mod
##     choosing, on the player's behalf, something the player had written down
##     and the mod could not read.
##
## `mods/pathtotarkov` is the one that gets this right in earnest: its defaults
## lock fifteen maps, so it calls `configFaulted()` first and, when the file is
## broken, writes nothing and moves nothing. This file is that argument in
## miniature, with a `stash` and a `whitelist` standing in for the maps.
##
## The concrete failure this prevents already happened here: the mod manager
## read a broken selection file, fell back to its default, and wrote out a
## selection naming only itself — a valid file, written confidently, containing
## a decision nobody made. Nothing in that sequence is a crash, and nothing in
## it logs an error unless somebody asks the question this file asks.
##
## ---------------------------------------------------------------------------
## WHAT IS MEASURED HERE AND WHAT IS ARGUED
## ---------------------------------------------------------------------------
##
## **Nothing in this repository has ever run against BSG's client**, and nothing
## in this file needs to have: config is entirely host-side and all three hosts
## implement it through one function, `configRead` in `host/common/modhost.nim`.
## So what this example shows is observed rather than argued — the simulator,
## the backend and the client host return `ErrConfigParse` from the same code,
## and `aowl run` exercises it for real.
##
## The one thing that is argued: that a broken file means the *player's* intent
## is unknown rather than absent. That is a judgement about people, not a fact
## about JSON, and it is why this mod refuses rather than repairing.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

# The settings, and the defaults they would fall back to. Written as literals
# so a reader can see exactly what would be chosen on their behalf.
var cfgEnabled = false
var cfgStashRows = 10
var cfgWhitelist: seq[string] = @[]

var refused = false
var faults = 0

proc fault(msg: string) =
  ## A failed self-check. `error` is what makes a simulator run exit non-zero,
  ## which is how `aowl test` sees any of this.
  inc faults
  error msg

proc textList(key: string): seq[string] =
  ## A JSON array of strings out of the config. Empty when the key is absent —
  ## which is safe here only because nothing reads this until `readConfig` has
  ## already established that the file itself is readable.
  result = @[]
  let v = setting(key)
  if not v.ok or v.raw.len < 2:
    return
  let list = whole(v.raw)
  if not isArray(list):
    return
  let items = each(list)
  for it in items:
    let s = asText(it, "")
    if s.len > 0:
      result.add s

# ---------------------------------------------------------------------------
# The three answers, told apart
# ---------------------------------------------------------------------------

proc describe(key: string) =
  ## What one `setting()` call actually knows, printed in full — and then what
  ## the one-line reading of it would have produced.
  ##
  ## `ok` and `faulted` are two bits and they encode three states; `asText`
  ## reduces all of them to one string, and that reduction is the bug. Seen side
  ## by side, "the file is unreadable" and "you never set this" hand back the
  ## identical value.
  let v = setting(key)
  var state = "absent"
  if v.ok:
    state = "present"
  elif v.faulted:
    state = "UNREADABLE (the file did not parse)"
  info "  setting(\"" & key & "\"): ok=" & $v.ok & " faulted=" & $v.faulted &
       " -> " & state
  info "      asText(\"<default>\") would hand back: \"" &
       asText(v, "<default>") & "\""

proc readConfig() =
  ## `configFaulted()` first, and it decides whether anything else is read.
  ##
  ## It is one call and one round trip — it asks for the whole document with an
  ## empty key — and it is asked once, at load, rather than at each `setting`,
  ## because the answer is a property of the file and not of the key. That is
  ## also why it must come first: a faulted file answers `ErrConfigParse` to
  ## *every* key, so a mod that reads its settings first and checks afterwards
  ## has already assigned twelve defaults by the time it finds out.
  refused = configFaulted()
  if refused:
    error "config.json is present and does not parse (" & lastError() & ")."
    error "  Nothing is enabled and nothing is written. The settings this mod " &
          "would otherwise fall back on are decisions about your game, not " &
          "defaults: an empty whitelist is not \"no preference\", it is \"let " &
          "nobody in\". Fix the file or delete it — deleting it is a " &
          "different, supported thing, and this mod runs on defaults then."
    cfgEnabled = false
    cfgStashRows = 0
    cfgWhitelist = @[]
    return

  cfgEnabled = setting("enabled").asBool(false)
  cfgStashRows = setting("stashRows").asInt(10)
  if cfgStashRows < 1: cfgStashRows = 1
  if cfgStashRows > 64: cfgStashRows = 64
  cfgWhitelist = textList("whitelist")

# ---------------------------------------------------------------------------
# The self-checks
# ---------------------------------------------------------------------------
#
# The same assertions hold in both runs — the shipped one, whose config parses,
# and the broken-config one described at the top of this file — because they are
# assertions about the *relationship* between `configFaulted()` and `setting()`
# rather than about either run. That is deliberate: a check that only fires in
# the good case would not have caught any of this.

proc check() =
  if configFaulted():
    # A faulted file poisons every key, including ones that are plainly in it.
    let known = setting("enabled")
    if known.ok:
      fault "configFaulted() is true but setting(\"enabled\") came back ok. " &
            "One of the two is lying and a mod cannot tell which."
    if not known.faulted:
      fault "configFaulted() is true but ConfigValue.faulted is false for a " &
            "key. The per-key answer and the whole-file answer must agree, or " &
            "checking either one proves nothing."
    # And the bytes come back even though the parse did not, which is what lets
    # a mod that parses its own document say *what* is wrong with the file.
    let whole1 = setting("")
    if whole1.raw.len == 0:
      fault "a faulted config handed back no bytes at all, so this mod could " &
            "not show the file it is complaining about"
    else:
      info "  the host still hands back the " & $whole1.raw.len &
           " bytes on disk, so the file can be shown to whoever has to fix it"
    if refused:
      success "refused: no setting was applied and no default was chosen"
    else:
      fault "the config is faulted and this mod did not refuse"
  else:
    # The other half, and the one that makes the distinction real: an *absent*
    # key on a *healthy* file is `ok=false, faulted=false`. Same `ok`, same
    # `asText` default, different fact. A mod that only looks at `ok` cannot
    # see the difference, and every example before this one only looked at `ok`.
    let absent = setting("thisKeyIsNotInTheFile")
    if absent.ok:
      fault "a key that is not in config.json came back ok"
    if absent.faulted:
      fault "a missing key on a healthy file reported faulted; then " &
            "\"unreadable\" and \"unset\" are the same answer again and " &
            "nothing above this line means anything"
    if refused:
      fault "the config parses and this mod refused anyway"
    let whole1 = setting("")
    if not whole1.ok:
      fault "the whole document did not read back on a healthy config"
    success "config read: enabled=" & $cfgEnabled & " stashRows=" &
            $cfgStashRows & " whitelist=" & $cfgWhitelist.len & " entry(s)"

proc onState(url, body, session: string): string =
  ## Whether this mod applied its config, and what it applied.
  ##
  ## A **bare** body, on purpose, and it is the right answer here: this is a
  ## private `/aowlspt/*` path that only your own tooling calls. The moment the
  ## caller is the game — anything under `/client/*` — this would have to be
  ## `envelope(o)` instead, for the reason `examples/envelope` exists.
  var o = obj()
  put(o, "ok", not refused)
  put(o, "refused", refused)
  put(o, "reason", (if refused: lastError() else: ""))
  put(o, "enabled", cfgEnabled)
  put(o, "stashRows", cfgStashRows)
  var list = arr()
  for w in cfgWhitelist:
    add(list, w)
  put(o, "whitelist", list)
  result = done(o).text

proc onLoad(): Status =
  success "strictconfig loaded on " & hostName() & " (side " & $ord(side()) & ")"

  readConfig()

  info "---- what one setting() call knows ----"
  describe("enabled")
  describe("thisKeyIsNotInTheFile")

  check()

  # What the one-liner would have done, said out loud in both runs. In the
  # healthy run these two lines agree with the real ones and the point is
  # invisible; in the broken run they are the whole failure, printed next to
  # the refusal so the two readings of the same file sit together.
  let asIfCareless = setting("whitelist")
  info "the one-line reading — setting(\"enabled\").asBool(false) — yields " &
       $asBool(setting("enabled"), false) & ", and setting(\"whitelist\") " &
       "yields " & (if asIfCareless.ok: "the list in the file" else:
                    "an empty list") & ". Neither call can tell you whether " &
       "that came from the file or from this sentence."

  # Routes, not because config needs them, but because "what did the mod
  # actually decide" is a question worth being able to ask over the wire — and
  # because the answer has to include *whether it decided at all*.
  #
  # `!= sideClient`, not `== sideServer`: the simulator serves routes and
  # presents as `sim`, so the narrower guard registers nothing under `aowl run`.
  if side() != sideClient:
    discard serve("/aowlspt/strictconfig/state", onState)

  Ok

proc onUnload(): Status =
  info "strictconfig unloading (" & (if refused: "refused" else: "applied") &
       ", " & $faults & " self-check failure(s))"
  Ok

exportMod(
  guid = "aowl.strictconfig",
  name = "Strict Config",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUnload = onUnload)
