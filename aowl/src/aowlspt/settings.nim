## aowlspt/settings — a mod declares its config schema, the F12 settings UI
## renders it, and an edit made in-game is written back through the same
## `config.json` the mod already reads.
##
## The problem this solves. Every mod already has a `config.json` and reads it
## with `setting("key").asFloat(default)`. Nothing anywhere says what those keys
## *are* — their type, their range, whether the value is even wired to
## anything. So there is no way for a settings screen to draw the right control
## for a key, and no way for it to warn that a key is read-and-ignored. This
## module is where a mod says all of that once, in code, next to the handler
## that reads it.
##
##     import aowlspt/settings
##
##     proc onLoad(): Status =
##       declareSettings(@[
##         floatSetting("opticFovMulti", "Optic FOV multiplier", 1.0,
##                      lo = 0.5, hi = 2.0, step = 0.01,
##                      category = "FOV",
##                      description = "FOV scale while aiming a magnified sight"),
##         boolSetting("changeMouseSensitivity", "Scale mouse sensitivity", true,
##                     category = "Sensitivity"),
##         keybindSetting("zoomToggleKey", "Toggle-zoom key", "M",
##                        category = "Toggle zoom",
##                        implemented = false,
##                        description = "Not wired: KeyCode enum mapping is missing")])
##       ...
##
## The declaration is pure data. It is serialised to the JSON the overlay's
## settings panel fetches (`schemaJson`), and it never itself touches the
## runtime — a mod that declares a schema and does nothing else is still a
## no-op mod. `implemented = false` is the honest half: aowlspt ports upstream
## mods a capability at a time, and a key whose value is carried but not yet
## acted on is drawn greyed with that reason rather than pretended to work.

import ".." / aowlspt            # configSet, Status, Ok, ErrBadArg
import "." / server              # Json, JsonObject, obj, put, arr, jstr, setting, asText/Float/Int/Bool
import "." / json                # field, raw, asText, exists — for the edit a POST carries

# ---------------------------------------------------------------------------
# The schema
# ---------------------------------------------------------------------------

type
  SettingType* = enum
    ## The control the UI draws. `stKeybind` is a string underneath — the value
    ## on disk is a key name like `"KeypadMultiply"` — but it is drawn as a
    ## key-capture box rather than a free text field, which is the whole reason
    ## it is a type of its own and not `stString`.
    stBool
    stInt
    stFloat
    stEnum
    stString
    stKeybind
    stSelect
      ## A choice out of a LARGE set -- thousands of item ids, say. Same value
      ## shape as `stEnum` (a string), and a UI that knows nothing about it can
      ## fall back to drawing it as an enum; the distinction is that a renderer
      ## is told up front to draw a searchable typeahead rather than a `<select>`
      ## with ten thousand `<option>`s in it, and that the choices may be fetched
      ## on demand from `optionsUrl` instead of shipped inline.

  Setting* = object
    key*: string          ## the config.json key, verbatim
    label*: string        ## the human name drawn on the row
    kind*: SettingType
    defaultJson*: string  ## the default as a JSON literal (`1.0`, `true`, `"M"`)
    lo*: float            ## min, for stInt/stFloat
    hi*: float            ## max
    step*: float          ## slider granularity
    hasRange*: bool       ## lo/hi/step are meaningful
    options*: seq[string] ## the choices, for stEnum
    category*: string     ## the sub-page/section this row groups under
    subcategory*: string  ## an optional second level INSIDE `category`
    optionLabels*: seq[string] ## display names parallel to `options`, or empty
    optionsUrl*: string   ## for stSelect: a route serving choices on demand
    description*: string  ## one sentence of help
    implemented*: bool    ## false → drawn greyed with the reason in `description`

proc kindName*(k: SettingType): string =
  ## The wire name of a type, matching what the UI switches on.
  case k
  of stBool:    result = "bool"
  of stInt:     result = "int"
  of stFloat:   result = "float"
  of stEnum:    result = "enum"
  of stString:  result = "string"
  of stKeybind: result = "keybind"
  of stSelect:  result = "select"

# ---------------------------------------------------------------------------
# Builders — one per type, so a mod never hand-fills the object
# ---------------------------------------------------------------------------
#
# Each returns a fully-formed `Setting`. The optional trailing arguments are the
# metadata a good row carries but a terse one can leave off; the defaults are
# chosen so the shortest possible call still produces a usable control.

proc boolSetting*(key, label: string; default: bool;
                  category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stBool,
                   defaultJson: (if default: "true" else: "false"),
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented)

proc intSetting*(key, label: string; default: int;
                 lo = 0; hi = 0; step = 1;
                 category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stInt,
                   defaultJson: $default,
                   lo: float(lo), hi: float(hi), step: float(step),
                   hasRange: hi > lo,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented)

proc floatSetting*(key, label: string; default: float;
                   lo = 0.0; hi = 0.0; step = 0.0;
                   category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stFloat,
                   defaultJson: $default,
                   lo: lo, hi: hi, step: step, hasRange: hi > lo,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented)

proc enumSetting*(key, label: string; default: string; options: seq[string];
                  category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stEnum,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: options, category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "",
                   description: description, implemented: implemented)

proc stringSetting*(key, label: string; default: string;
                    category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stString,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented)

proc keybindSetting*(key, label: string; default: string;
                     category = ""; subcategory = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stKeybind,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented)

proc selectSetting*(key, label: string; default: string; options: seq[string];
                    optionLabels: seq[string] = @[]; optionsUrl = "";
                    category = ""; subcategory = ""; description = "";
                    implemented = true): Setting =
  ## A choice out of a set too large to draw as a `<select>` -- an item id out
  ## of the whole handbook, a map, a trader. The VALUE is a plain string, the
  ## same as `enumSetting`, so nothing about persistence or `configSet`
  ## changes; only the control a renderer picks does.
  ##
  ## Two ways to supply the choices, and a row may use both:
  ##
  ## * `options` (with optional `optionLabels`, a parallel array of display
  ##   names) ships the choices inline in the schema. Fine for hundreds.
  ## * `optionsUrl` names a route the UI queries as the user types --
  ##   `GET <optionsUrl>?q=<term>&limit=<n>` returning
  ##   `{"options":[{"value":"...","label":"..."}...]}`. This is the one that
  ##   scales to thousands of item ids, because the schema stays small and the
  ##   mod that owns the ids does the searching.
  ##
  ## A renderer that has never heard of `select` and falls through to its
  ## `enum` branch still draws a working control from `options`; that is why
  ## the value shape was kept identical rather than introducing an object.
  result = Setting(key: key, label: label, kind: stSelect,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: options, category: category, subcategory: subcategory,
                   optionLabels: optionLabels, optionsUrl: optionsUrl,
                   description: description,
                   implemented: implemented)

# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

proc settingPath*(s: Setting): seq[string] =
  ## The GROUP PATH this row lives at, to ARBITRARY DEPTH.
  ##
  ## `category` and `subcategory` stayed exactly as they were -- every mod that
  ## has already declared settings keeps working, unedited, and keeps getting
  ## the same one- or two-level grouping it had. Depth beyond two is expressed
  ## by putting separators IN `category` (or `subcategory`):
  ##
  ##     category = "Player/Health/Regeneration"
  ##
  ## which yields the path `["Player", "Health", "Regeneration"]` and renders
  ## as `Singleplayer > Player > Health > Regeneration`. That was chosen over
  ## adding a `path: seq[string]` argument to all seven builders because it
  ## changes NO existing call site and no existing wire field: `category` and
  ## `subcategory` are still emitted verbatim next to `path`, so a renderer
  ## that has never heard of `path` (the served web UI, an older overlay)
  ## degrades to the two-level grouping it already drew rather than to
  ## nothing.
  ##
  ## Empty segments are dropped, so `"A//B"`, `"/A/B"` and `"A/B/"` all mean
  ## `["A", "B"]` -- a stray separator must not produce an unnamed group, which
  ## is precisely the "a group renders with no title" defect this exists to
  ## make unrepresentable.
  result = @[]
  for part in [s.category, s.subcategory]:
    var cur = ""
    for ch in part:
      if ch == '/':
        if cur.len > 0: result.add cur
        cur = ""
      else:
        cur.add ch
    if cur.len > 0: result.add cur

proc toJson*(s: Setting): JsonObject =
  ## One row, as the UI receives it. `value` is the *current* value read out of
  ## `config.json` (falling back to `defaultJson` when the file has no such
  ## key), so the panel can be drawn without a second round trip.
  var o = obj()
  o.put("key", s.key)
  o.put("label", s.label)
  o.put("type", kindName(s.kind))
  o.put("default", Json(text: s.defaultJson))
  var cur = setting(s.key)
  # `cur.raw` is the on-disk text for the key, but hosts disagree on whether a
  # string-shaped value comes back with its JSON quotes still on (see
  # `asText`'s docstring) -- so for the three text-shaped kinds the only safe
  # thing is to strip via `asText` and re-quote/escape through `jstr`, the same
  # helper the `key`/`label` string fields above already go through. For the
  # numeric/bool kinds the on-disk text is already a bare JSON literal either
  # way, so it is used verbatim.
  if cur.ok:
    case s.kind
    of stEnum, stString, stKeybind, stSelect:
      o.put("value", jstr(asText(cur, "")))
    of stBool, stInt, stFloat:
      o.put("value", Json(text: cur.raw))
  else:
    o.put("value", Json(text: s.defaultJson))
  if s.hasRange:
    o.put("min", s.lo)
    o.put("max", s.hi)
    o.put("step", s.step)
  if s.options.len > 0:
    var a = arr()
    for opt in s.options:
      a.add opt
    o.put("options", a)
  if s.optionLabels.len > 0 and s.optionLabels.len == s.options.len:
    # Parallel to `options`, and emitted ONLY when it is exactly parallel --
    # a labels array of a different length would silently mislabel a control,
    # which is worse than a UI showing raw ids.
    var la = arr()
    for lb in s.optionLabels:
      la.add lb
    o.put("optionLabels", la)
  if s.optionsUrl.len > 0: o.put("optionsUrl", s.optionsUrl)
  if s.subcategory.len > 0: o.put("subcategory", s.subcategory)
  if s.category.len > 0:  o.put("category", s.category)
  # The same grouping as an explicit, ordered path -- see `settingPath`. Always
  # emitted when the row is grouped at all, so a renderer never has to re-derive
  # it by re-splitting two fields and never has to guess which of them is the
  # outer one.
  block:
    let segs = settingPath(s)
    if segs.len > 0:
      var pa = arr()
      for seg in segs:
        pa.add seg
      o.put("path", pa)
  if s.description.len > 0: o.put("description", s.description)
  o.put("implemented", s.implemented)
  result = o

proc schemaJson*(settings: seq[Setting]): Json =
  ## A whole schema as a JSON array, current values folded in.
  var a = arr()
  for s in settings:
    a.add toJson(s)
  result = done(a)

# ---------------------------------------------------------------------------
# The per-mod registry
# ---------------------------------------------------------------------------
#
# A mod calls `declareSettings` once, from `onLoad`. The declaration is held so
# a route handler can serve it without the mod threading the seq through itself.

var gDeclared: seq[Setting] = @[]
var gAnnounceSubscribed = false

const
  SettingsIndexQuery* = "aowlspt.settings.indexQuery"
    ## Broadcast by the `/aowlspt/settings/index` aggregator (see
    ## `mods/settingshub`). Every mod that has ever called `declareSettings`
    ## replies synchronously with `SettingsIndexAnnounce` — see `emit`/`on` in
    ## `aowlspt.nim`: `deliverEvent` calls every subscriber before returning,
    ## so by the time the query's `emit` call returns, the aggregator has
    ## already heard from everybody. This is the same synchronous
    ## broadcast-then-collect shape the host's own mod-control replies use
    ## (`deliverEvent`'s comment: "the mod-control replies come from here").
    ##
    ## Chosen over a process-wide registry proc (design doc §6, option 1)
    ## because that would need a new export on the mod ABI, and
    ## `abi/**`/`host/**` are off limits to this change; chosen over N
    ## loopback HTTP calls (option 2) because there is no in-process route
    ## dispatch exposed to a mod, only the real network listener, and a real
    ## HTTP round-trip per mod per index fetch — through TLS, on the request
    ## thread that is itself serving the index route — is worse than one
    ## broadcast. `on`/`emit` already exist and already cross mods without
    ## either knowing the other exists, which is exactly this problem.
  SettingsIndexAnnounce* = "aowlspt.settings.indexAnnounce"
    ## Payload: `{"guid":"...","name":"...","count":N,"done":M}`. Emitted by
    ## every mod that has declared settings, once per `SettingsIndexQuery` it
    ## hears. `done` is how many of the `count` rows are `implemented`.
  SettingsPageQuery* = "aowlspt.settings.pageQuery"
    ## Payload: a bare guid. The mod whose `modGuid()` matches replies with
    ## `SettingsPageAnnounce`; every other subscriber ignores it.
    ##
    ## This is the event twin of `GET /aowlspt/settings/<guid>`, and it exists
    ## because **the client host refuses `route_register`**: a client-only mod
    ## (`mods/graphics` is `sides = {sideClient}`) registers its settings route
    ## into nothing, so its page was unreachable BY CONSTRUCTION -- and the
    ## `/aowlspt/settings/index` aggregator in `mods/settingshub` is server-side,
    ## so its `SettingsIndexQuery` broadcast never reached a client-only mod
    ## either. The event bus IS implemented on the client
    ## (`aowlspt_nim_event_emit` in the client host), so it is the only
    ## in-process channel a client mod's schema can travel on.
  SettingsPageAnnounce* = "aowlspt.settings.pageAnnounce"
    ## Payload: `{"guid":"...","rows":[ ...schema... ]}` -- the same rows the
    ## GET route returns, so one reader parses both transports.
  SettingsApplyQuery* = "aowlspt.settings.applyQuery"
    ## Payload: `{"guid":"...","key":"...","value":<literal>}`. The owning mod
    ## persists it through the SAME `applySettingFromBody` its route uses and
    ## then runs its apply hook (`onSettingsApplied`), so the edit HOT-APPLIES
    ## in the process that owns the runtime. That is the point: a page that
    ## renders but whose edits never reach the live instance is worse than an
    ## absent page, so the schema and the write travel the same way.
  SettingsApplyAnnounce* = "aowlspt.settings.applyAnnounce"
    ## Payload: `{"guid":"...","ok":true|false,"err":"...","rows":[...]}`.
    ## `rows` is the schema RE-READ after the write, never an echo of what was
    ## asked for, so a caller verifies by value and not by "the call returned"
    ## (fact #135: a chunked POST is answered 200 with the schema unchanged).

proc onIndexQuery(payload: string): string =
  if gDeclared.len > 0:
    var o = obj()
    o.put("guid", modGuid())
    o.put("name", modName())
    o.put("count", gDeclared.len)
    # How many of them are actually BACKED. The index has always carried
    # `count`; without a companion `done` a consumer cannot tell a mod with six
    # working settings from one with six placeholders, and the overlay's
    # "hide what is not implemented" filter would have had to fetch every page
    # to find out that a page has nothing to show. `mods/settingshub` already
    # sends `done` for each SPT page (0, for all of them), so this makes both
    # halves of the settings index answer the same question in the same field.
    #
    # An explicit 0 therefore MEANS "none of these do anything yet" and is
    # distinct from the field being absent, which means "this index did not
    # say". A consumer must not treat the two alike.
    var impl = 0
    for s in gDeclared:
      if s.implemented: inc impl
    o.put("done", impl)
    discard emit(SettingsIndexAnnounce, done(o).text)
  result = ""

proc declaredSettings*(): seq[Setting] =
  ## What this mod declared, for a route handler that serves it.
  result = gDeclared

proc declaredSchemaJson*(): Json =
  ## This mod's declared schema, current values folded in — the body a
  ## `/aowlspt/settings/<guid>` route returns.
  result = schemaJson(gDeclared)

proc statusMessage(st: Status): string =
  case st
  of Ok: "ok"
  of ErrBadArg: "the POST body was not {\"key\":...,\"value\":...}"
  of ErrNotFound: "no such declared key on this mod"
  of ErrConfigParse: "this mod's config.json does not parse; lastError() names why"
  of ErrUnsupported: "this host does not support writing config"
  else: "could not persist (status " & $st & ")"

proc declaredSchemaReply*(applyStatus: Status): Json =
  ## The reply a route sends after a POST (edit or reset) attempt. `Ok`
  ## replies with the bare array `GET` always returned — the wire shape both
  ## the F12 overlay and the fallback page already parse. Anything else wraps
  ## the SAME rows in `{"err":...,"rows":[...]}` instead: a caller that only
  ## ever checked `Array.isArray` on the reply could not tell a persisted
  ## write from a discarded one, which is the exact 200-with-unchanged-echo
  ## shape this whole change exists to stop being silent. `rows` still carries
  ## the current schema so a caller that has not been updated to look at
  ## `err` degrades to "did not refresh" rather than "threw".
  if applyStatus == Ok:
    return schemaJson(gDeclared)
  var o = obj()
  o.put("err", statusMessage(applyStatus))
  var a = arr()
  for s in gDeclared:
    a.add toJson(s)
  o.put("rows", done(a))
  result = done(o)

# ---------------------------------------------------------------------------
# Writing an edit back
# ---------------------------------------------------------------------------

proc applySetting*(key, valueJson: string): Status =
  ## Persist one edit into this mod's `config.json`. `valueJson` is a JSON
  ## literal — `"1.0"`, `"true"`, `"\"M\""`. The host merges it into the file;
  ## a mod that wants the new value live re-reads it (most call their own
  ## `loadConfig` again) rather than this function applying it, because only the
  ## mod knows which of its runtime writes a given key feeds.
  result = configSet(key, valueJson)

proc applySettingFromBody*(body: string): Status =
  ## The edit a settings-UI POST carries, applied. The body is
  ## `{"key":"<configKey>","value":<literal>}` — the F12 overlay's write-back
  ## shape — where `value` is a JSON literal (`1.5`, `true`, `"KeypadMultiply"`).
  ## The key is one of this mod's own config keys and the value is persisted
  ## verbatim, quotes and all, into `config.json`.
  ##
  ## `ErrBadArg` when the body is not that shape, so a route handler can serve
  ## the schema back regardless and the panel simply shows the unchanged value.
  ## A mod that wants the new value live re-reads its config after this returns
  ## `Ok` — the same rule as `applySetting`, and for the same reason.
  let k = field(body, "key")
  let v = field(body, "value")
  if not k.exists or not v.exists:
    return ErrBadArg
  let key = k.asText("")
  if key.len == 0:
    return ErrBadArg
  result = applySetting(key, v.raw)
  if result != Ok:
    # The route handler's contract is "reply with the schema regardless" (see
    # the docstring above), which means a failed persist and a successful one
    # produce the same 200 with a JSON array either way -- the "renders but
    # changes nothing" shape this whole change exists to stop being silent.
    # The host log is the one channel left that can say so without changing
    # that wire shape.
    warn "settings: POST for \"" & key & "\" did not persist (status " &
         $result & ") -- the reply still echoes the schema, unchanged"

# ---------------------------------------------------------------------------
# Reset to declared default
# ---------------------------------------------------------------------------
#
# The schema is the one place a default lives (`Setting.defaultJson`, filled
# in by every `xSetting` builder above). A reset writes that same literal back
# through `applySetting` -- the identical write path a normal edit takes, key
# creation included -- so a reset can never drift from an edit's idea of what
# "default" means, and a reset on a key `config.json` has never held (this
# module's whole bug) works for exactly the same reason the fix above does.

proc findDeclared(key: string): int =
  ## Index into `gDeclared` of `key`, or -1. Declared once per mod and short
  ## (single digits to a few dozen rows), so a linear scan costs nothing next
  ## to the file write that follows it.
  result = -1
  for i, s in gDeclared:
    if s.key == key:
      return i

proc resetSetting*(key: string): Status =
  ## Reset one declared key to the value its builder call declared as
  ## `default`. `ErrNotFound` for a key this mod never declared -- resetting
  ## an unknown key is not "no-op successfully", it is "there is nothing to
  ## reset", and the caller should see that rather than a silent 200.
  let i = findDeclared(key)
  if i < 0:
    return ErrNotFound
  result = applySetting(key, gDeclared[i].defaultJson)

proc resetAllSettings*(): Status =
  ## Reset every declared key of this mod to its default. Stops at the first
  ## failure and reports that key's status -- a partial reset with no
  ## indication of where it stopped would be worse than refusing outright.
  result = Ok
  for s in gDeclared:
    let st = applySetting(s.key, s.defaultJson)
    if st != Ok:
      warn "settings: reset of \"" & s.key & "\" did not persist (status " &
           $st & ")"
      return st

proc resetFromBody*(body: string): Status =
  ## The body a reset POST may carry: `{"key":"<configKey>"}` resets that one
  ## key; an empty body (no `key` field, or an empty body entirely) resets
  ## every key this mod declared. Mirrors `applySettingFromBody`'s shape.
  let k = field(body, "key")
  if body.len == 0 or not k.exists:
    return resetAllSettings()
  let key = k.asText("")
  if key.len == 0:
    return resetAllSettings()
  result = resetSetting(key)

# ---------------------------------------------------------------------------
# The in-process bus: how a CLIENT-side mod's page reaches the settings screen
# ---------------------------------------------------------------------------
#
# Everything above assumes an HTTP route. The client host does not have one --
# it refuses `route_register` outright, because the game process serves no
# HTTP -- so for a mod whose `sides` is `{sideClient}` the whole route half of
# this module is dead code, and `/aowlspt/settings/index` (served server-side
# by `mods/settingshub`) has never had any way to hear about it. That is why
# `mods/graphics`' twenty fully-wired settings were INVISIBLE in F12: not a
# rendering bug, an unreachable transport.
#
# The fix is not to give a client mod a server side -- that would make the page
# APPEAR while its edits landed in a different process from the runtime they
# configure, which is a half-working control. It is to carry the same schema
# and the same write over the one channel the client host does implement:
# events. `declareSettings` subscribes every mod to both queries below, and the
# client host (`host/Aowlspt.Host.Il2Cpp/settingsbridge.nim`) drives them and
# forwards the result to the backend so the F12 nav can list the mod.

type
  SettingsApplyHook* = nil proc (key: string)
    ## Run after a `SettingsApplyQuery` edit has persisted, so the mod can
    ## re-read its config and push the change into whatever it drives.
    ## Nilable -- nimony proc types are non-nil by default, hence `nil proc`.

var gApplyHook: SettingsApplyHook = nil
var gBusSubscribed = false

proc onSettingsApplied*(cb: SettingsApplyHook) =
  ## Register the hot-apply hook. A mod without one still gets its page and
  ## still persists edits -- it just will not SHOW them until it next re-reads
  ## its config, and a control that moves and changes nothing is the exact
  ## failure this whole mechanism exists to avoid. Register one.
  gApplyHook = cb

proc onPageQuery(payload: string): string =
  if payload == modGuid() and gDeclared.len > 0:
    var o = obj()
    o.put("guid", modGuid())
    o.put("rows", schemaJson(gDeclared))
    discard emit(SettingsPageAnnounce, done(o).text)
  result = ""

proc onApplyQuery(payload: string): string =
  let g = field(payload, "guid")
  if not g.exists or g.asText("") != modGuid():
    return ""
  # A reset arrives on the same query, flagged, because it is the same
  # question -- "make this key be X" -- and splitting it into a second event
  # would give the client transport a second code path to rot in.
  var st = Ok
  if field(payload, "reset").asBool(false):
    st = resetFromBody(payload)
  else:
    st = applySettingFromBody(payload)
  if st == Ok and gApplyHook != nil:
    let k = field(payload, "key")
    gApplyHook(k.asText(""))
  var o = obj()
  o.put("guid", modGuid())
  o.put("ok", st == Ok)
  if st != Ok:
    o.put("err", statusMessage(st))
  o.put("rows", schemaJson(gDeclared))
  discard emit(SettingsApplyAnnounce, done(o).text)
  result = ""

proc declareSettings*(settings: seq[Setting]) =
  ## Register this mod's schema. Replaces any previous declaration — call it
  ## once with the whole list, not once per row.
  gDeclared = settings
  if not gAnnounceSubscribed and settings.len > 0:
    # Subscribe once, lazily, the first time a mod actually has something to
    # announce — a mod that never declares settings never joins the
    # broadcast at all, which keeps a no-op `declareSettings(@[])` cheap and
    # keeps the fan-out list free of mods with nothing to say.
    discard on(SettingsIndexQuery, onIndexQuery)
    gAnnounceSubscribed = true
  if not gBusSubscribed and settings.len > 0:
    # The page/apply twins of the route pair. Subscribed for EVERY mod, not
    # only client-side ones: a server mod answering both transports costs one
    # ignored event per query and keeps ONE code path for both sides, so the
    # client transport cannot quietly rot while only the server one is used.
    discard on(SettingsPageQuery, onPageQuery)
    discard on(SettingsApplyQuery, onApplyQuery)
    gBusSubscribed = true
