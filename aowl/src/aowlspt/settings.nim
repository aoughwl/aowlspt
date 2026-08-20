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

# ---------------------------------------------------------------------------
# Builders — one per type, so a mod never hand-fills the object
# ---------------------------------------------------------------------------
#
# Each returns a fully-formed `Setting`. The optional trailing arguments are the
# metadata a good row carries but a terse one can leave off; the defaults are
# chosen so the shortest possible call still produces a usable control.

proc boolSetting*(key, label: string; default: bool;
                  category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stBool,
                   defaultJson: (if default: "true" else: "false"),
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, description: description,
                   implemented: implemented)

proc intSetting*(key, label: string; default: int;
                 lo = 0; hi = 0; step = 1;
                 category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stInt,
                   defaultJson: $default,
                   lo: float(lo), hi: float(hi), step: float(step),
                   hasRange: hi > lo,
                   options: @[], category: category, description: description,
                   implemented: implemented)

proc floatSetting*(key, label: string; default: float;
                   lo = 0.0; hi = 0.0; step = 0.0;
                   category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stFloat,
                   defaultJson: $default,
                   lo: lo, hi: hi, step: step, hasRange: hi > lo,
                   options: @[], category: category, description: description,
                   implemented: implemented)

proc enumSetting*(key, label: string; default: string; options: seq[string];
                  category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stEnum,
                   defaultJson: "\"" & default & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: options, category: category,
                   description: description, implemented: implemented)

proc stringSetting*(key, label: string; default: string;
                    category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stString,
                   defaultJson: "\"" & default & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, description: description,
                   implemented: implemented)

proc keybindSetting*(key, label: string; default: string;
                     category = ""; description = ""; implemented = true): Setting =
  result = Setting(key: key, label: label, kind: stKeybind,
                   defaultJson: "\"" & default & "\"",
                   lo: 0.0, hi: 0.0, step: 0.0, hasRange: false,
                   options: @[], category: category, description: description,
                   implemented: implemented)

# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------

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
  if cur.ok:
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
  if s.category.len > 0:  o.put("category", s.category)
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

proc declareSettings*(settings: seq[Setting]) =
  ## Register this mod's schema. Replaces any previous declaration — call it
  ## once with the whole list, not once per row.
  gDeclared = settings

proc declaredSettings*(): seq[Setting] =
  ## What this mod declared, for a route handler that serves it.
  result = gDeclared

proc declaredSchemaJson*(): Json =
  ## This mod's declared schema, current values folded in — the body a
  ## `/aowlspt/settings/<guid>` route returns.
  result = schemaJson(gDeclared)

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
