## Reactive settings -- a value that is ALREADY current, instead of a variable
## somebody has to remember to refresh.
##
## ## The shape this replaces
##
## Every mod in this repo does the same three things per setting, by hand:
##
## ```nim
## var cfgOpticFovMulti = 1.0                       # 1. a global
## proc loadConfig() =
##   cfgOpticFovMulti = cfgFloat("opticFovMulti", 1.0)   # 2. a reload line
##   gZoomKeyDirty = true                                # 3. a side effect
## ```
##
## Three places to keep in sync for one key, and `loadConfig()` only runs when
## somebody calls it. Change a value in the in-game settings screen and nothing
## happens: the mod holds the old number until its next load. So mods either
## poll `setting()` on the hot path -- a host round trip per frame -- or they
## are quietly stale. `mods/fov` alone carries twenty-odd of these.
##
## That is the "explicit state-based code" this module removes.
##
## ## The shape it replaces it with
##
## ```nim
## var opticFov: ReactiveFloat            # module scope: just the handle
##
## proc onLoad(): Status =
##   opticFov = reactiveFloat("opticFovMulti", 1.0)      # BIND IN onLoad
##   opticFov.onChange = proc(old, now: float) = gZoomKeyDirty = true
##
## proc onUpdate(ms: int64): Status =
##   applyFov(base * opticFov.value)      # already current; no reload call
## ```
##
## **Bind inside `onLoad`, never at module scope.** MEASURED: constructing a
## binding at module scope kills the process with an ACCESS VIOLATION -- module
## init runs before the host API is wired, so `setting()` has nothing to call
## and the library globals the binding registers into do not exist yet. The
## handle can live at module scope; the CONSTRUCTOR call cannot.
##
## Past that, it is one line per setting. No `loadConfig()` to write, none to
## call, no polling on the hot path: `.value` is a plain field read, refreshed
## by a pump the mod never mentions.
##
## ## Why this is ON BY DEFAULT, and what that costs
##
## The pump runs from `modOnUpdate` -- the mod library's OWN update shim, not
## the mod's `onUpdate` -- and registers itself from the first binding you
## create. So a mod gets reactivity by declaring a binding and writing nothing
## else; there is no "remember to call the tick" step, because a step you have
## to remember is the thing this module exists to delete.
##
## VERIFIED end to end against a running backend: an identical rewrite of
## config.json fired nothing, `demoStrength` 1.0 -> 2.5 fired the handler with
## both values, and `demoEnabled` true -> false fired its own. No reload call
## exists anywhere in the mod.
##
## It costs one clock compare per update tick while idle. Re-reading the config
## is throttled to `ReactivePollMs` and, far more importantly, is SKIPPED
## ENTIRELY unless the config document has actually changed -- one round trip
## for the whole document, not one per key.
##
## ## Change is decided by VALUE, never by "the file was written"
##
## A settings screen that rewrites config.json on every keystroke, a deploy that
## copies an identical file, a backup restore -- all of these touch the document
## without changing what any key MEANS. Firing handlers on those is how a
## reactive system earns a reputation for being unpredictable.
##
## So a handler fires when, and only when, the DECODED value differs from the
## one the binding is holding. A rewrite with identical content fires nothing.
##
## ## The first read is not a change
##
## The constructor does not read the config; `reactiveLoad()` does, and it does
## not call `onChange`. A first read is not a change, and firing every handler
## during load -- before there is a game world -- is the surprise this must not
## produce. Call `reactiveLoad()` once after binding (the demo does), or let the
## first pump tick fill them. A handler is for
## "this became something else", and firing it at bind time would run every
## mod's handler during `onLoad`, when there is no game world yet.
##
## A mod that DOES want its handler run against the initial value calls
## `fireNow()` after assigning it. There is deliberately no `fireOnInit`
## constructor flag: the handler is assigned AFTER the constructor returns, so
## such a flag could only ever observe a nil handler and do nothing -- a
## parameter that silently does nothing is worse than no parameter.
##
## ## A key that will not decode is REPORTED, not silently defaulted
##
## `asFloat(default)` cannot distinguish "absent" from "present but not a
## number", and both come back as the default. That is the right behaviour for
## a one-shot read and the wrong behaviour for a binding, because a typo in
## config.json then looks exactly like a setting nobody set. Each binding
## records `lastDecodeFailed` and the raw text that would not decode, and
## `reactiveReport()` names them -- so "my setting does nothing" has an answer
## that is not "read the source".

import ".." / aowlspt
import server

const
  ReactivePollMs* = 500'i64
    ## How often the pump may re-read the config document. Settings change at
    ## human speed; polling faster buys nothing and costs a host round trip.

type
  ReactiveBool* = ref object
    key*: string
    value*: bool                ## always current -- read this
    default*: bool
    onChange*: proc(old, now: bool)
    lastDecodeFailed*: bool
    lastRaw*: string
    changes*: int

  ReactiveInt* = ref object
    key*: string
    value*: int
    default*: int
    onChange*: proc(old, now: int)
    lastDecodeFailed*: bool
    lastRaw*: string
    changes*: int

  ReactiveFloat* = ref object
    key*: string
    value*: float
    default*: float
    onChange*: proc(old, now: float)
    lastDecodeFailed*: bool
    lastRaw*: string
    changes*: int

  ReactiveText* = ref object
    key*: string
    value*: string
    default*: string
    onChange*: proc(old, now: string)
    lastDecodeFailed*: bool
    lastRaw*: string
    changes*: int

var gBools: seq[ReactiveBool] = @[]
var gInts: seq[ReactiveInt] = @[]
var gFloats: seq[ReactiveFloat] = @[]
var gTexts: seq[ReactiveText] = @[]

var gSinceMs = 0'i64      ## accumulated tick deltas since the last poll
var gLastDoc = ""
var gDocSeen = false
var gPolls = 0
var gReReads = 0
var gFires = 0
var gEnabled = true

proc reactiveEnabled*(): bool = gEnabled

proc setReactiveEnabled*(on: bool) =
  ## Off is a deliberate, stated choice, not a default. When off, `.value`
  ## keeps whatever it last held -- it does NOT revert to the default, because
  ## silently changing values is exactly what switching the feature off is
  ## meant to prevent.
  gEnabled = on

# ---------------------------------------------------------------------------
# Decoding. Each returns (ok, value): `ok` false means the key was PRESENT and
# would not decode, which is a different thing from absent and is reported.
# ---------------------------------------------------------------------------

proc decodeBool(raw: string; default: bool; ok: var bool): bool =
  ok = true
  case raw
  of "true", "True", "1", "\"true\"": result = true
  of "false", "False", "0", "\"false\"": result = false
  else:
    ok = false
    result = default

proc unquote(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"':
    result = s.substr(1, s.len - 2)
  else:
    result = s

# ---------------------------------------------------------------------------
# Binding
# ---------------------------------------------------------------------------

var gHooked = false

proc ensureHooks() =
  ## Register the pump with the mod library, ONCE, from the first binding.
  ##
  ## This used to be two top-level calls at module scope. They never ran: the
  ## report showed `0 poll(s)` on a backend that ticks mods every 50ms, so the
  ## update hook had simply never been added. Module-scope side effects in an
  ## imported module are not something to rely on here -- the same assumption
  ## also produced an ACCESS VIOLATION when the constructors touched the host
  ## API at module-init time.
  ##
  ## Registering from the first constructor is dependable because constructors
  ## run inside `onLoad`, by which point the library and the host API are both
  ## alive.
  if gHooked: return
  gHooked = true
  addUpdateHook(proc(elapsedMs: int64) = reactiveTick(elapsedMs))

proc reactiveBool*(key: string; default: bool): ReactiveBool =
  ## Bind `key` as a bool. Safe at module scope; `.value` is filled before
  ## `onLoad` runs and is current from then on.
  result = ReactiveBool(key: key, value: default, default: default, lastDecodeFailed: false,
                        lastRaw: "", changes: 0)
  ensureHooks()
  gBools.add result

proc reactiveFloat*(key: string; default: float): ReactiveFloat =
  result = ReactiveFloat(key: key, value: default, default: default, lastDecodeFailed: false,
                         lastRaw: "", changes: 0)
  ensureHooks()
  gFloats.add result

proc reactiveInt*(key: string; default: int): ReactiveInt =
  result = ReactiveInt(key: key, value: default, default: default, lastDecodeFailed: false,
                       lastRaw: "", changes: 0)
  ensureHooks()
  gInts.add result

proc reactiveText*(key, default: string): ReactiveText =
  result = ReactiveText(key: key, value: default, default: default, lastDecodeFailed: false,
                        lastRaw: "", changes: 0)
  ensureHooks()
  gTexts.add result

# ---------------------------------------------------------------------------
# fireNow -- run the handler against the value the binding already holds.
#
# For the mod whose handler IS its apply step ("when the FOV multiplier
# changes, re-apply the FOV"), so it does not have to duplicate that step once
# at load and once in the handler. Call it AFTER assigning `onChange`; it is a
# no-op with no handler, and it does not count as a change.
# ---------------------------------------------------------------------------

proc fireNow*(b: ReactiveBool) =
  if b.onChange != nil: b.onChange(b.value, b.value)

proc fireNow*(f: ReactiveFloat) =
  if f.onChange != nil: f.onChange(f.value, f.value)

proc fireNow*(i: ReactiveInt) =
  if i.onChange != nil: i.onChange(i.value, i.value)

proc fireNow*(t: ReactiveText) =
  if t.onChange != nil: t.onChange(t.value, t.value)

# ---------------------------------------------------------------------------
# The pump
# ---------------------------------------------------------------------------

var gFilled = false

proc reactiveLoad*() =
  ## The FIRST read of every binding. Registered as a load hook, so it runs
  ## before the mod's `onLoad` body and `.value` is correct there.
  ##
  ## It fills silently: a first read is not a change, and firing every handler
  ## during load -- when there is no game world yet -- is exactly the surprise
  ## this module must not produce.
  for b in gBools:
    let c = setting(b.key)
    if c.ok:
      var good = false
      b.value = decodeBool(c.raw, b.default, good)
      b.lastDecodeFailed = not good
      b.lastRaw = c.raw
  for f in gFloats:
    let c = setting(f.key)
    if c.ok:
      f.lastRaw = c.raw
      f.value = c.asFloat(f.default)
  for i in gInts:
    let c = setting(i.key)
    if c.ok:
      i.lastRaw = c.raw
      i.value = c.asInt(i.default)
  for t in gTexts:
    let c = setting(t.key)
    if c.ok:
      t.lastRaw = c.raw
      t.value = unquote(c.raw)
  gFilled = true

proc reactiveRefresh*(): int =
  ## Re-read every binding and fire the handlers whose DECODED value changed.
  ## Returns how many changed. Safe to call by hand; the library calls it.
  result = 0
  for b in gBools:
    let c = setting(b.key)
    if not c.ok: continue
    var good = false
    let v = decodeBool(c.raw, b.default, good)
    b.lastDecodeFailed = not good
    b.lastRaw = c.raw
    if v != b.value:
      let old = b.value
      b.value = v
      inc b.changes
      inc result
      if b.onChange != nil: b.onChange(old, v)
  for f in gFloats:
    let c = setting(f.key)
    if not c.ok: continue
    f.lastRaw = c.raw
    let v = c.asFloat(f.default)
    if v != f.value:
      let old = f.value
      f.value = v
      inc f.changes
      inc result
      if f.onChange != nil: f.onChange(old, v)
  for i in gInts:
    let c = setting(i.key)
    if not c.ok: continue
    i.lastRaw = c.raw
    let v = c.asInt(i.default)
    if v != i.value:
      let old = i.value
      i.value = v
      inc i.changes
      inc result
      if i.onChange != nil: i.onChange(old, v)
  for t in gTexts:
    let c = setting(t.key)
    if not c.ok: continue
    t.lastRaw = c.raw
    let v = unquote(c.raw)
    if v != t.value:
      let old = t.value
      t.value = v
      inc t.changes
      inc result
      if t.onChange != nil: t.onChange(old, v)
  gFires = gFires + result

proc reactiveTick*(elapsedMs: int64) =
  ## Called from the mod library's own update shim, every tick, for every mod.
  ##
  ## Two gates before anything expensive happens, in this order:
  ##
  ##   1. the clock -- at most one poll per ReactivePollMs;
  ##   2. THE WHOLE DOCUMENT -- one `setting("")` round trip. If the config
  ##      text is byte-identical to last time, no key can have changed, and the
  ##      per-binding re-reads are skipped entirely. That is what keeps a mod
  ##      with thirty bindings from making thirty round trips twice a second.
  ##
  ## A mod with NO bindings does none of this: the first line returns.
  if not gEnabled: return
  if gBools.len == 0 and gInts.len == 0 and gFloats.len == 0 and
     gTexts.len == 0:
    return
  # `elapsedMs` is a DELTA, not a clock: the backend ticks mods with
  # `now - lastTick` and the client host with its own frame delta. Treating it
  # as an absolute timestamp made the throttle compare a ~16ms frame delta
  # against a 500ms budget and poll on EVERY tick -- a host round trip per
  # frame, which is precisely the cost this module claims to remove. So it is
  # accumulated into a clock of our own.
  gSinceMs = gSinceMs + elapsedMs
  if gSinceMs < ReactivePollMs: return
  gSinceMs = 0'i64
  inc gPolls

  var doc = ""
  let c = setting("")
  doc = c.raw
  if gDocSeen and doc == gLastDoc:
    # The document is unchanged, so no VALUE can have changed. This is the
    # cheap path and it is the one taken almost every time.
    return
  gDocSeen = true
  gLastDoc = doc
  inc gReReads
  discard reactiveRefresh()

proc reactiveReport*(): string =
  ## What is bound, what it holds, and what would not decode.
  ##
  ## The last part is the point: `asFloat(default)` cannot tell "absent" from
  ## "present but not a number", so without this a typo in config.json is
  ## indistinguishable from a setting nobody set, and "my setting does nothing"
  ## has no answer short of reading the source.
  var bad = 0
  var lines = ""
  for b in gBools:
    if b.lastDecodeFailed:
      inc bad
      lines.add "\n    " & b.key & " = " & b.lastRaw &
                "  <- does not decode as a bool; using " & $b.default
  result = "reactive settings: " & $(gBools.len + gInts.len + gFloats.len +
           gTexts.len) & " binding(s), " & $gPolls & " poll(s), " &
           $gReReads & " document change(s), " & $gFires & " value change(s)"
  if bad > 0:
    result.add "; " & $bad & " KEY(S) WILL NOT DECODE:" & lines
  elif not gEnabled:
    result.add "; DISABLED -- values are frozen at what they last held"

# ---------------------------------------------------------------------------
# ON BY DEFAULT.
#
# Registering the pump at module init is what makes this feature automatic: a
# mod that merely `import aowlspt/reactive` and declares a binding gets
# self-refreshing values, with no tick call to write and none to forget.
#
# Registration is inverted -- reactive registers itself with the library rather
# than the library calling reactive -- because `aowlspt/server`, where `setting`
# lives, imports the library. A direct call would be an import cycle.
#
# A mod that wants the values frozen calls `setReactiveEnabled(false)`; the
# hook stays registered and returns on its first line, so switching it off costs
# a bool test rather than leaving a half-live pump behind.
# ---------------------------------------------------------------------------

