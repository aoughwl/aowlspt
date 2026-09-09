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
    stColor
      ## A COLOUR, drawn as a picker (saturation/value field + hue strip + RGBA
      ## sliders + a hex box), stored as a STRING.
      ##
      ## The on-disk shape is deliberately the one the host ALREADY parses for
      ## `panelColor`/`espColor` in `aowlspt-debugui.json` -- `"r,g,b"` or
      ## `"r,g,b,a"`, each component a decimal in 0..1. That choice is the whole
      ## reason this is a safe addition rather than a migration: `stColor` is a
      ## RENDERING HINT over `stString`'s exact value shape, the same way
      ## `stSelect` is a hint over `stEnum`'s. Every existing colour key on disk
      ## (they are all `stringSetting` today) keeps parsing, byte for byte, and a
      ## renderer that has never heard of `color` degrades to the free-text box
      ## it draws right now -- which is the current behaviour, so nothing can
      ## regress by adding this.
      ##
      ## Alpha is OPTIONAL and preserved: a value that arrives with three
      ## components is written back with three, so a target that has no alpha
      ## channel never grows a spurious fourth number in its config.

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
    colorFormat*: string  ## for stColor ONLY: the ON-DISK TEXT SHAPE the owning
                          ## mod's own parser reads back. `""`/`"rgb"` is the
                          ## default `"r,g,b[,a]"` in 0..1; `"hex"` is bare
                          ## `RRGGBB[AA]`; `"hex#"` is `#RRGGBB[AA]`.
                          ##
                          ## This exists because the picker is SHARED and the
                          ## parsers are not. `mods/maps` reads its contact
                          ## colours with `parseRgb`, which requires EXACTLY six
                          ## hex digits and returns the DEFAULT on anything else
                          ## -- so a picker that wrote `"0.9,0.27,0.24"` into
                          ## `colorBot` would leave the dot on screen at its old
                          ## colour while config.json held the new one. That is
                          ## the "control that moves and changes nothing"
                          ## failure, and it is unrepresentable now: the row
                          ## declares the shape its own reader parses, and the
                          ## widget writes that shape.
                          ##
                          ## A renderer that has never heard of this field falls
                          ## back to `"rgb"`, which is what every existing colour
                          ## row already uses, so nothing can regress by adding
                          ## it.
    description*: string  ## one sentence of help
    keybind*: bool        ## THE KEYBIND FACET. `true` means "this row belongs to
                          ## the key-binding surface", which is a WIDER claim than
                          ## `kind == stKeybind` and deliberately separate from it.
                          ##
                          ## `stKeybind` is a VALUE SHAPE (a key NAME string, drawn
                          ## as a capture box). Two kinds of row are keybinds to a
                          ## player and cannot be that shape:
                          ##
                          ## * a key stored as a VIRTUAL-KEY CODE -- `mods/debug`'s
                          ##   `overlayToggleKey` is `114` (VK_F3) and its reader
                          ##   parses an int. Retyping it `stKeybind` would change
                          ##   the on-disk shape under a parser that would then
                          ##   read the default instead. It declares the facet.
                          ## * the GATE for a key -- `mods/maps` and `mods/admin`
                          ##   both have a bool `hotkeys` that must be ON before
                          ##   any key is polled at all. A "keybinds only" view
                          ##   that hid the gate would show a key that provably
                          ##   does nothing and no way to find out why. That is
                          ##   the "control that changes nothing" failure, so the
                          ##   gates declare the facet too.
                          ##
                          ## The alternative -- a filter that pattern-matches names
                          ## containing "key" -- gets BOTH directions wrong on this
                          ## repo's real data: it would hide `hotkeys`/`overlay
                          ## ToggleKey`-style gates it did not recognise, and it
                          ## would show `mods/loadammoanim`'s `hijackKey`, which is
                          ## a BUNDLE NAME and not a key at all. Declared, not
                          ## guessed.
                          ##
                          ## `keybindSetting` sets this itself; nothing else has
                          ## to. Read it through `isKeybind`, never directly.
    implemented*: bool    ## false → drawn greyed with the reason in `description`
    appliesOn*: string    ## when an edit takes effect: `"live"` (default) or
                          ## `"restart"`. A row that CANNOT take effect until the
                          ## game is relaunched must say `"restart"` here, so the
                          ## panel can label it. A control that changes nothing
                          ## and does not say why is the failure this whole
                          ## mechanism exists to stop; "restart" is an honest
                          ## answer, silence is not. NOTE: this is unrelated to
                          ## `mods/manager`'s `appliesOn` wire field, which
                          ## carries a mod's SIDE (`client`/`server`/`both`).

proc isKeybind*(s: Setting): bool =
  ## THE single predicate for "is this row part of the key-binding surface".
  ## Every filter, in every renderer, must ask this and nothing else -- the
  ## whole point of the facet is that there is one answer and it is declared.
  result = s.kind == stKeybind or s.keybind

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
  of stColor:   result = "color"

# ---------------------------------------------------------------------------
# Builders — one per type, so a mod never hand-fills the object
# ---------------------------------------------------------------------------
#
# Each returns a fully-formed `Setting`. The optional trailing arguments are the
# metadata a good row carries but a terse one can leave off; the defaults are
# chosen so the shortest possible call still produces a usable control.

proc boolSetting*(key, label: string; default: bool;
                  category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live";
                  keybind = false): Setting =
  ## `keybind = true` for a row that GATES a key (see `Setting.keybind`) -- a
  ## bool is not a key, but hiding the gate from a keybinds-only view leaves a
  ## key on screen that cannot fire.
  result = Setting(key: key, label: label, kind: stBool,
                   defaultJson: (if default: "true" else: "false"),
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented, appliesOn: appliesOn, keybind: keybind)

proc intSetting*(key, label: string; default: int;
                 lo = 0; hi = 0; step = 1;
                 category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live";
                 keybind = false): Setting =
  ## `keybind = true` for a key stored as a VIRTUAL-KEY CODE. The int stays an
  ## int on disk -- the facet is metadata, not a retype, so the mod's own parser
  ## is untouched.
  result = Setting(key: key, label: label, kind: stInt,
                   defaultJson: $default,
                   lo: float(lo), hi: float(hi), step: float(step),
                   hasRange: hi > lo,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented, appliesOn: appliesOn, keybind: keybind)

proc floatSetting*(key, label: string; default: float;
                   lo = 0.0; hi = 0.0; step = 0.0;
                   category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live"): Setting =
  result = Setting(key: key, label: label, kind: stFloat,
                   defaultJson: $default,
                   lo: lo, hi: hi, step: step, hasRange: hi > lo,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented, appliesOn: appliesOn)

proc enumSetting*(key, label: string; default: string; options: seq[string];
                  category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live"): Setting =
  result = Setting(key: key, label: label, kind: stEnum,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: options, category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "",
                   description: description, implemented: implemented, appliesOn: appliesOn)

proc stringSetting*(key, label: string; default: string;
                    category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live"): Setting =
  result = Setting(key: key, label: label, kind: stString,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented, appliesOn: appliesOn)

proc keybindSetting*(key, label: string; default: string;
                     category = ""; subcategory = ""; description = ""; implemented = true; appliesOn = "live"): Setting =
  result = Setting(key: key, label: label, kind: stKeybind,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", description: description,
                   implemented: implemented, appliesOn: appliesOn, keybind: true)

const
  cColorFmtRgb* = "rgb"
    ## `"r,g,b"` / `"r,g,b,a"`, components 0..1. THE DEFAULT.
  cColorFmtHex* = "hex"
    ## `"rrggbb"` / `"rrggbbaa"` -- NO leading `#`.
  cColorFmtHexHash* = "hex#"
    ## `"#rrggbb"` / `"#rrggbbaa"` -- WITH the leading `#`.

proc normalizeColorFormat*(fmt: string): string =
  ## THE ONE PLACE a colour format string is validated. Every producer and every
  ## consumer goes through this or through the three constants above, so the two
  ## UIs cannot drift apart on a bare literal -- which is exactly what happened:
  ## the native settings renderer parsed `#rrggbb` only, while the default
  ## format every mod gets is `r,g,b`, so every default-format colour row was
  ## demoted to an unbound text stub in game while the web picker worked.
  if fmt == cColorFmtHex or fmt == cColorFmtHexHash: fmt else: cColorFmtRgb

proc colorSetting*(key, label: string; default: string;
                   category = ""; subcategory = ""; description = "";
                   implemented = true; appliesOn = "live";
                   format = cColorFmtRgb): Setting =
  ## A colour row. `default` is `"r,g,b"` or `"r,g,b,a"`, components in 0..1 --
  ## the exact text the host's `duParseRgb` already reads out of
  ## `aowlspt-debugui.json`, so switching an existing `stringSetting` colour key
  ## to this builder changes the DRAWN CONTROL and nothing on disk.
  ##
  ## Note what is deliberately NOT done here: the default is not normalised,
  ## re-formatted or round-tripped through a float. A colour that goes in as
  ## `"1,1,0.62"` is stored as `"1,1,0.62"`. Re-formatting is how a colour picks
  ## up drift -- `0.62` becoming `0.6200000000000001` on every save -- and drift
  ## in a value the user typed is indistinguishable, from the outside, from the
  ## setting not persisting.
  ##
  ## `format` names the TEXT SHAPE the owning mod's own reader parses -- see
  ## `Setting.colorFormat`. Leave it alone unless the mod already parses hex;
  ## `"hex"`/`"hex#"` exist so an EXISTING hex key can be upgraded from a bare
  ## text box to this picker without touching a byte of what is on disk.
  let fmt = normalizeColorFormat(format)
  result = Setting(key: key, label: label, kind: stColor,
                   defaultJson: "\"" & server.escapeText(default) & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, subcategory: subcategory,
                   optionLabels: @[], optionsUrl: "", colorFormat: fmt,
                   description: description,
                   implemented: implemented, appliesOn: appliesOn)

proc selectSetting*(key, label: string; default: string; options: seq[string];
                    optionLabels: seq[string] = @[]; optionsUrl = "";
                    category = ""; subcategory = ""; description = "";
                    implemented = true; appliesOn = "live"): Setting =
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
                   implemented: implemented, appliesOn: appliesOn)

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

proc currentValueJson*(s: Setting): Json =
  ## The CURRENT value of one declared row, as the JSON literal the wire
  ## carries, read back out of `config.json` -- or the declared default when
  ## the file has no such key.
  ##
  ## Split out of `toJson` (which is all it used to be) so that a WRITE can
  ## answer with a READBACK rather than an echo. `POST .../set` returns what
  ## this proc reads AFTER the write, so a caller that compares it against what
  ## it sent is comparing against the store, not against its own request --
  ## fact #135 is exactly the case where those two differ and the echo lies.
  var cur = setting(s.key)
  # `cur.raw` is the on-disk text for the key, but hosts disagree on whether a
  # string-shaped value comes back with its JSON quotes still on (see
  # `asText`'s docstring) -- so for the text-shaped kinds the only safe thing
  # is to strip via `asText` and re-quote/escape through `jstr`, the same
  # helper the `key`/`label` string fields go through. For the numeric/bool
  # kinds the on-disk text is already a bare JSON literal either way, so it is
  # used verbatim.
  if not cur.ok:
    return Json(text: s.defaultJson)
  case s.kind
  of stEnum, stString, stKeybind, stSelect, stColor:
    result = jstr(asText(cur, ""))
  of stBool, stInt, stFloat:
    result = Json(text: cur.raw)

proc toJson*(s: Setting): JsonObject =
  ## One row, as the UI receives it. `value` is the *current* value read out of
  ## `config.json` (falling back to `defaultJson` when the file has no such
  ## key), so the panel can be drawn without a second round trip.
  var o = obj()
  o.put("key", s.key)
  o.put("label", s.label)
  o.put("type", kindName(s.kind))
  o.put("default", Json(text: s.defaultJson))
  o.put("value", currentValueJson(s))
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
  # Emitted for EVERY colour row, never conditionally on it being non-default:
  # a renderer must be able to tell "this row wants r,g,b" from "this row said
  # nothing", and once one colour row carries a format an absent field on the
  # next one reads as an omission rather than as a choice.
  if s.kind == stColor:
    o.put("colorFormat", normalizeColorFormat(s.colorFormat))
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
  # Always emitted, never conditionally: a renderer must be able to tell
  # "this row applies live" from "this row said nothing", and an absent field
  # cannot carry that difference.
  o.put("appliesOn", (if s.appliesOn.len > 0: s.appliesOn else: "live"))
  # Always emitted, never conditionally, for the same reason as `appliesOn`: a
  # keybinds-only filter has to be able to tell "declared NOT a keybind" from
  # "this server is too old to have an opinion". An absent field cannot carry
  # that, and a filter that reads absence as `false` would silently empty itself
  # against an older backend and look broken rather than say so.
  o.put("keybind", isKeybind(s))
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
var gPublished = false
  ## THE SCHEMA HAS BEEN PUBLISHED AND IS NOW IMMUTABLE. Set once, at the end
  ## of `declareSettings`, and never cleared.
  ##
  ## It exists because `gDeclared` is read from a DIFFERENT THREAD than the one
  ## that writes it. `SettingsPageQuery` arrives on the client host's tick
  ## thread (measured: a crash stack of `toJson` <- `schemaJson` <-
  ## `onPageQuery` <- `eventTrampoline` <- six host frames <-
  ## `BaseThreadInitThunk`), while `declareSettings` runs on whichever thread
  ## released the mod. `gDeclared = settings` DESTROYS the previous seq before
  ## it stores the new one, so a second declaration frees, under a reader's
  ## feet, the 12 KB buffer that reader is walking element by element.
  ##
  ## Measured, from the minidump of the 2026-09-02 03:00 crash
  ## (`tools/dmpread.py`): the faulting read was
  ## `gDeclared.data[20].optionsUrl.more_0` with the pointer equal to
  ## `0xdfdfdfdfdfdfdfdf` -- mimalloc's `MI_DEBUG_FREED` fill. The seq header
  ## on the stack said `len = 54, data = 0x21dd2053000`, and the faulting
  ## address was exactly `data + 20 * sizeof(Setting)`, so the INDEX was in
  ## range and the arithmetic was right: the buffer itself had been freed.
  ##
  ## So a schema is published ONCE and then never replaced. Nothing in this
  ## repository loses anything by that -- `mods/admin` is the only mod with two
  ## `declareSettings` call sites and they are on mutually exclusive paths, so
  ## no mod declares twice on one run.
var gAnnounceSubscribed = false
var gInIndex = true
  ## Whether this mod gets its OWN entry in the F12 nav. False means the
  ## schema is still served, still page-queryable and still writable -- it
  ## is simply not a top-level mod in the list, because another mod presents
  ## these rows inside its own page tree.

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
  # Same publish gate as `onPageQuery`, and for the same reason: this walks
  # `gDeclared` on the emitting thread. Not logged here, deliberately -- the
  # index query is broadcast every bridge cycle to every mod, so a mod with no
  # settings would print a line every five seconds; the page query, which names
  # ONE guid, is where the refusal is worth saying out loud.
  if schemaPublishReason().len > 0: return ""
  if gDeclared.len > 0 and gInIndex:
    var o = obj()
    o.put("guid", modGuid())
    o.put("name", modName())
    # The version this page belongs to. Always emitted (empty string when a mod
    # declared none), because an ABSENT field would mean "this backend is too
    # old to say" and an empty one means "this mod named no version" -- a
    # consumer that cannot tell those apart will print a stale number from
    # somewhere else rather than admit it does not know.
    o.put("version", modVersion())
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

proc schemaPublishReason*(): string =
  ## `""` when the schema is published and safe to serialise; otherwise ONE
  ## sentence saying why it is not, in the words the refusal will be logged in.
  ##
  ## THREE OUTCOMES, NOT TWO (CLAUDE.md 9b). "ready" and "this mod declared no
  ## settings" are different answers and a caller must be able to tell them
  ## apart: the first means serialise, the second means there is nothing to
  ## serialise and never will be, and neither is "I could not look".
  if gPublished and gDeclared.len > 0:
    return ""
  if gPublished:
    return "settings schema publish-once: this mod published an EMPTY schema"
  result = "settings schema publish-once: nothing has been published yet -- " &
           "declareSettings has not returned, so there is no schema to " &
           "serialise and reading one would read memory nobody owns"

proc declaredSchemaJson*(): Json =
  ## This mod's declared schema, current values folded in — the body a
  ## `/aowlspt/settings/<guid>` route returns.
  result = schemaJson(gDeclared)

proc statusMessage(st: Status): string =
  case st
  of Ok: "ok"
  of ErrBadArg: "the POST body was not {\"key\":...,\"value\":...}"
  # NOT "no such declared key". That wording was a CAUSE asserted from a
  # status that does not carry one, and it was wrong for the case that
  # actually happens. Measured 2026-08-28 against the live client: the F3
  # profiler toggle produced, on the same millisecond,
  #   "config set profiler on aowl.debug did not persist: no config.json for aowl.debug"
  #   "'aowl.debug' refused an F12 edit: no such declared key on this mod"
  # `profiler` IS declared -- it is in debug.nim's schema and in the repo's
  # mods/debug/config.json -- and the second line sent whoever read it looking
  # for a schema bug that does not exist. The client host answers ErrNotFound
  # for BOTH "the file has no such key" and "there is no file", and from here
  # the two are indistinguishable, so this now names both and points at
  # `lastError()`, which does know which. Say what was observed, not why.
  of ErrNotFound: "the host did not persist it and reported ErrNotFound. " &
                  "That is EITHER no config.json for this mod at all -- in " &
                  "which case nothing this mod declares can ever be saved -- " &
                  "OR a key the schema does not declare. lastError() " &
                  "distinguishes them; check the mod's config.json exists first"
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
  ##
  ## OBSERVABILITY, and why it is here rather than in each transport. This is
  ## the ONE proc every settings write in this process passes through --
  ## `applySettingFromBody` (the route and the bus both), `resetSetting`,
  ## `resetAllSettings` and `backfillDeclaredDefaults`. A write logged per
  ## transport can only ever name the transports we already knew about; logged
  ## here, a transport nobody has thought of still announces itself. That is
  ## what the maps OFF-toggle hunt needed and did not have: three transports
  ## were each patched and the bug survived, with nothing in the log saying
  ## which process had done the write.
  result = configSet(key, valueJson)
  info "settings: config write " & modGuid() & "." & key & " = " & valueJson &
       " -> " & (if result == Ok: "stored" else: statusMessage(result))

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

# ---------------------------------------------------------------------------
# What the mod DID with the value — the missing half of the apply path
# ---------------------------------------------------------------------------
#
# The notification path already existed (`onSettingsApplied`, below) and both
# `mods/graphics` and `mods/fov` already registered a hook. What did NOT exist
# was any way for a hook to say what it did, so nothing downstream could tell
# apart:
#
#   * the mod re-read its config and pushed the change into the live runtime,
#   * the mod cannot change this live and needs a relaunch,
#   * the mod deliberately ignored the value (a preset owns that slider, a
#     master switch is off, the feature is not armed in this session),
#   * the mod has no hook at all.
#
# All four produced the single line "applied an F12 edit to '<guid>'", which
# means only "the value reached config.json" and reads as success. That one
# line is why nine graphics edits and one grade push looked like a working
# feature. Every branch below now names itself.
#
# The mod reports by CALLING one of these from inside its hook. Not by a return
# value: `SettingsApplyHook` is already registered by five mods and by two
# tests, and a signature change there is a wide edit with nothing to gain --
# a hook that reports nothing is a distinguishable state on its own ("ran but
# said nothing"), which is exactly what we want to be able to see.

const
  ApplyEffectApplied*  = "applied"
  ApplyEffectRestart*  = "restart"
  ApplyEffectIgnored*  = "ignored"
  ApplyEffectNoHook*   = "nohook"
  ApplyEffectSilent*   = "unreported"

var gApplyEffect = ""
var gApplyDetail = ""

proc settingApplied*(detail = "") =
  ## Call from inside an apply hook: the change is IN FORCE NOW, and `detail`
  ## should name the value that is now live (not the value that was stored --
  ## those differ whenever a preset, a clamp or a master switch is involved).
  gApplyEffect = ApplyEffectApplied
  gApplyDetail = detail

proc settingAppliesOnRestart*(detail = "") =
  ## Call from inside an apply hook: stored, but it cannot take effect until
  ## the game is relaunched. This is a legitimate answer; silence is not.
  gApplyEffect = ApplyEffectRestart
  gApplyDetail = detail

proc settingIgnored*(reason: string) =
  ## Call from inside an apply hook: stored, and deliberately NOT acted on.
  ## `reason` is mandatory, because "ignored" without a reason is the same
  ## dead end as saying nothing.
  gApplyEffect = ApplyEffectIgnored
  gApplyDetail = reason

proc onSettingsApplied*(cb: SettingsApplyHook) =
  ## Register the hot-apply hook. A mod without one still gets its page and
  ## still persists edits -- it just will not SHOW them until it next re-reads
  ## its config, and a control that moves and changes nothing is the exact
  ## failure this whole mechanism exists to avoid. Register one.
  gApplyHook = cb

proc onPageQuery(payload: string): string =
  if payload == modGuid():
    # THE REFUSAL IS LOGGED, NEVER SILENT (CLAUDE.md 6). This handler runs on
    # whichever thread emitted the query -- on the client that is the host's
    # tick thread, not the thread that loaded this mod -- so "the schema is not
    # there yet" is a real state and answering nothing without saying so is the
    # failure mode this whole file argues against.
    let why = schemaPublishReason()
    if why.len > 0:
      warn "settings: SettingsPageQuery for " & modGuid() &
           " REFUSED -- " & why
      return ""
    var o = obj()
    o.put("guid", modGuid())
    o.put("rows", schemaJson(gDeclared))
    discard emit(SettingsPageAnnounce, done(o).text)
  result = ""

proc onApplyQuery(payload: string): string =
  let g = field(payload, "guid")
  if not g.exists or g.asText("") != modGuid():
    return ""
  block:
    # An apply ENDS in `schemaJson(gDeclared)`, so it has the page query's
    # exposure as well as a write. Refuse before the write, not after it: a
    # value persisted whose readback cannot be served is worse than a refusal.
    let why = schemaPublishReason()
    if why.len > 0:
      warn "settings: SettingsApplyQuery for " & modGuid() &
           " REFUSED before any write -- " & why
      return ""
  # A reset arrives on the same query, flagged, because it is the same
  # question -- "make this key be X" -- and splitting it into a second event
  # would give the client transport a second code path to rot in.
  var st = Ok
  if field(payload, "reset").asBool(false):
    st = resetFromBody(payload)
  else:
    st = applySettingFromBody(payload)
  let key = field(payload, "key").asText("")
  # THE STORE AND THE EFFECT ARE TWO DIFFERENT EVENTS. `st` is the store; the
  # three fields below are the effect. They are reported separately all the way
  # to the host log, because conflating them is the bug.
  gApplyEffect = ""
  gApplyDetail = ""
  if st == Ok and gApplyHook != nil:
    gApplyHook(key)
    if gApplyEffect.len == 0:
      # The hook RAN and reported nothing. Not a failure -- but not a success
      # either, and it must not be printed as one. A row declared
      # `appliesOn = "restart"` is the one case where silence has a documented
      # meaning, so honour that; otherwise say plainly that nobody knows.
      let i = findDeclared(key)
      if i >= 0 and gDeclared[i].appliesOn == "restart":
        gApplyEffect = ApplyEffectRestart
        gApplyDetail = "declared appliesOn=restart"
      else:
        gApplyEffect = ApplyEffectSilent
  elif st == Ok:
    let i = findDeclared(key)
    if i >= 0 and gDeclared[i].appliesOn == "restart":
      gApplyEffect = ApplyEffectRestart
      gApplyDetail = "declared appliesOn=restart"
    else:
      gApplyEffect = ApplyEffectNoHook
  var o = obj()
  o.put("guid", modGuid())
  o.put("ok", st == Ok)
  o.put("key", key)
  # THE READBACK. Not an echo of what the request carried: this is
  # `config.json` re-read through `currentValueJson` after the write and after
  # the apply hook ran, so a caller that compares it with what it sent learns
  # whether the store took the value -- which is the one thing a 200 cannot
  # tell it (fact #135: a POST answered 200 with the schema unchanged).
  #
  # Emitted on FAILURE too, and that is the useful case: it is then the value
  # that is still in force, which is what the panel must go on drawing. A
  # `reset` (no `key` in the payload) resets everything and names no single
  # row, so there is nothing to read back and the field is omitted rather than
  # filled with a guess.
  block:
    let vi = findDeclared(key)
    if vi >= 0:
      o.put("value", currentValueJson(gDeclared[vi]))
  if st == Ok:
    o.put("effect", gApplyEffect)
    if gApplyDetail.len > 0:
      o.put("effectDetail", gApplyDetail)
  if st != Ok:
    o.put("err", statusMessage(st))
  o.put("rows", schemaJson(gDeclared))
  discard emit(SettingsApplyAnnounce, done(o).text)
  result = ""

proc backfillDeclaredDefaults*(settings: seq[Setting]): int =
  ## Write the declared default into `config.json` for every declared key the
  ## file does not already hold. Returns how many keys were added.
  ##
  ## THIS IS HOW A NEW KEY REACHES AN EXISTING INSTALL, and without it there
  ## was no such path at all. The deploy `seed` rule copies a mod's
  ## `config.json` only when the file is ABSENT -- deliberately, because
  ## overwriting one is overwriting the player's settings -- so a key added to
  ## the repo's config.json after the first deploy never arrives. That is
  ## exactly what happened to `progressionPlayerLevel`,
  ## `progressionSkillLevel` and `progressionMasteryLevel`: present in the
  ## repo, declared, wired to `emu/progression`, and absent from the live
  ## `mods/tarkov/config.json`, so `configGet` answered `ErrNotFound`, the rows
  ## rendered at their schema defaults and resolved to nothing.
  ##
  ## Backfill only, never overwrite: a key the file already holds is left
  ## alone, whatever its value, so a player's edits survive every upgrade. The
  ## only observable change to an install that is already complete is zero
  ## writes.
  ##
  ## A file that exists and does not PARSE is refused outright rather than
  ## backfilled: `configSet` would merge into a document we cannot read, and
  ## the honest answer to "which keys are missing" from an unparseable file is
  ## that we do not know. It warns and writes nothing.
  result = 0
  if settings.len == 0:
    return
  if configFaulted():
    warn "settings: this mod's config.json does not parse, so no declared " &
         "default was backfilled -- every setting on this mod is running on " &
         "its schema default and nothing can persist (" & lastError() & ")"
    return
  var added: seq[string] = @[]
  for s in settings:
    if setting(s.key).ok:
      continue
    let st = applySetting(s.key, s.defaultJson)
    if st == Ok:
      added.add s.key
    else:
      # One line per key would be N lines of the same fault; but silence here
      # is the very failure mode this proc exists to end, so the FIRST one
      # names the status and stops the loop -- if the mod has no config.json
      # at all, no later key will fare differently.
      warn "settings: could not backfill \"" & s.key & "\" into config.json " &
           "(" & statusMessage(st) & ") -- that row renders and resolves to " &
           "nothing"
      return added.len
  if added.len > 0:
    var names = ""
    for k in added:
      if names.len > 0: names.add ", "
      names.add k
    info "settings: backfilled " & $added.len & " declared key(s) missing " &
         "from config.json: " & names
  result = added.len

proc declareSettings*(settings: seq[Setting]; inIndex = true) =
  ## Register this mod's schema. Call it ONCE with the whole list, not once
  ## per row -- and a second call is REFUSED, loudly, rather than replacing
  ## the schema.
  ##
  ## It used to say "replaces any previous declaration", and replacing it is
  ## the measured crash: see `gPublished`. `gDeclared = settings` destroys the
  ## old seq first, and `onPageQuery` walks that same seq on the host's tick
  ## thread, so the replacement hands a live reader a freed 12 KB buffer. A
  ## refusal costs a mod nothing here (no mod in this repo declares twice on
  ## one path) and it makes the use-after-free unrepresentable rather than
  ## merely unlikely.
  if gPublished:
    warn "settings: declareSettings was called a SECOND time with " &
         $settings.len & " row(s). REFUSED and IGNORED: the first schema (" &
         $gDeclared.len & " row(s)) stays in force. Replacing it would free " &
         "the seq that this process's SettingsPageQuery handler may be " &
         "walking on another thread right now -- that is a measured crash, " &
         "not a theoretical one. Declare the whole schema in one call."
    gInIndex = inIndex
    return
  gDeclared = settings
  gInIndex = inIndex
  # PUBLISHED HERE, before the subscriptions below and before the backfill,
  # because from this line on `gDeclared` is immutable and every reader on
  # every thread may walk it. The subscriptions come after, so a query cannot
  # arrive before this flag is true.
  gPublished = true
  # Self-healing on load. See `backfillDeclaredDefaults`: the deploy seed rule
  # cannot carry a NEW key into an install that already has a config.json, so
  # without this every setting added after a player's first deploy is a control
  # that renders and does nothing, on their machine only, where no repo-side
  # check can see it.
  discard backfillDeclaredDefaults(settings)
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

# ---------------------------------------------------------------------------
# The two HTTP routes, which every server mod was writing out by hand
# ---------------------------------------------------------------------------

proc onSettingsRoute(url, body, session: string): string =
  result = declaredSchemaReply(applySettingFromBody(body)).text

proc onSettingsResetRoute(url, body, session: string): string =
  result = declaredSchemaReply(resetFromBody(body)).text

proc serveSettingsRoutes*(): Status =
  ## Register `/aowlspt/settings/<guid>` and `/aowlspt/settings/<guid>/reset`
  ## with the standard handlers.
  ##
  ## This existed already, four times, copied by hand: `mods/waypoints`,
  ## `mods/tarkov` and the rest each wrote the same two three-line handlers and
  ## the same two `serve` calls. Copied boilerplate is where the drift lives --
  ## a mod that spelled the route `/aowlspt/settings/<guid>/` with a trailing
  ## slash, or forgot the reset half, gets a settings page whose controls store
  ## nothing, and nothing anywhere says so.
  ##
  ## Call it AFTER `declareSettings`, from `onLoad`, on the server side. It is
  ## a no-op returning `Ok` when this mod declared no settings, so it is safe
  ## to call unconditionally.
  ##
  ## Not folded into `declareSettings` itself, deliberately: `declareSettings`
  ## is called on the client side too, where there is no route table, and a mod
  ## that already registers these routes by hand would double-register and get
  ## a conflict it did not ask for.
  if gDeclared.len == 0:
    return Ok
  let base = "/aowlspt/settings/" & modGuid()
  result = serve(base, onSettingsRoute)
  if result != Ok:
    warn "settings: could not register " & base &
         " -- this mod's settings page will not store anything"
    return
  let r = serve(base & "/reset", onSettingsResetRoute)
  if r != Ok:
    warn "settings: could not register " & base & "/reset -- Reset will fail"
    return r
