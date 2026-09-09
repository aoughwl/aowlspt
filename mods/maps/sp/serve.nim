## Serving the terrain, the calibration and the live snapshot.
##
## Everything here is ordinary file IO and string building on the backend's
## worker threads. Nothing in this file touches game memory, resolves an
## IL2CPP name, or runs on Unity's thread.
##
## ## Routes
##
##   GET /aowlspt/maps/index            the map list + calibration summary
##   GET /aowlspt/maps/map/<id>         one map's full calibration
##   GET /aowlspt/maps/asset/<path>     one terrain SVG
##   GET /aowlspt/maps/feed             the latest snapshot, or a stated reason
##   GET /aowlspt/maps/status           diagnostics, in words
##
## ## The path guard
##
## `/aowlspt/maps/asset/<path>` takes a caller-supplied relative path and opens
## a file with it. That is a directory traversal waiting to happen, so
## `safeRel` is a WHITELIST, not a blacklist: a segment must be non-empty and
## consist only of `[A-Za-z0-9._-]`, must not be `.` or `..`, and the whole
## path must end in `.svg`. A blacklist of "../" would miss `..%2f`, backslash
## separators and absolute paths; a whitelist cannot, because anything it has
## not heard of is refused by default.
##
## ## The snapshot file
##
## The client half writes `aowlspt-spatial.json` beside the backend, terminated
## by a sentinel the reader checks for (see `Sentinel` below). A reader that
## catches a half-written file would otherwise get invalid JSON and show
## nothing, which is indistinguishable from "not in a raid" -- the exact
## conflation this mod is careful about everywhere else.
##
## ## Every error body goes through the JSON builder
##
## MEASURED, by calling the route: an error message that interpolates a Windows
## path into a hand-written `"{\"reason\":\"...\"}"` emits raw backslashes and
## is **not valid JSON**, so the page's `JSON.parse` throws and the whole
## diagnostic -- the thing whose entire job is to explain why nothing is
## showing -- disappears. So every body below is built with `obj()`/`put()`,
## which escapes. Never hand-write a JSON string containing a path here.

import std/syncio
import aowlspt
import aowlspt/server as sv
import aowlspt/json
import world
import page

const
  IndexRoute*  = "/aowlspt/maps/index"
  MapPrefix*   = "/aowlspt/maps/map/"
  AssetPrefix* = "/aowlspt/maps/asset/"
  FeedRoute*   = "/aowlspt/maps/feed"
  StatusRoute* = "/aowlspt/maps/status"

  SnapshotName = "aowlspt-spatial.json"
  StaleAfterMs = 2000

var gMapsRoot = ""
var gIndexJson = ""
var gMapCount = 0
var gLayerCount = 0

proc mapsRoot*(): string = gMapsRoot
proc mapCount*(): int = gMapCount
proc layerCount*(): int = gLayerCount

# --------------------------------------------------------------------------
# File helpers. `readFile` raises in nimony, so every read goes through the
# non-raising open/readAll pair the rest of this repo uses.
# --------------------------------------------------------------------------

proc slurp(path: string; into: var string): bool =
  ## `readFile` is `{.raises.}` in nimony, so it is wrapped. A missing file and
  ## an unreadable one are the same answer here -- both mean "nothing to serve"
  ## -- and the caller turns that into a stated reason, never an empty body.
  into = ""
  var f: File
  try:
    if not open(f, path, fmRead): return false
  except:
    return false
  var got = ""
  var ok = false
  try:
    got = readAll(f)
    ok = true
  except:
    ok = false
  try: close(f)
  except: discard
  if not ok: return false
  into = got
  result = true

proc spill(path, body: string; err: var string): bool =
  err = ""
  try:
    writeFile(path, body)
  except:
    err = "could not write " & path
    return false
  result = true

proc joinp(a, b: string): string =
  if a.len == 0: return b
  if a[a.len - 1] == '\\' or a[a.len - 1] == '/': return a & b
  result = a & "\\" & b

# --------------------------------------------------------------------------
# The whitelist path guard
# --------------------------------------------------------------------------

proc stripQuery(s: string): string =
  ## `pathAfter` hands back everything after the prefix INCLUDING the query
  ## string, and every fetch from the page appends `?ident=1` (the backend
  ## deflates by default and browser JS may not set Accept-Encoding). Measured:
  ## without this, a request for a real asset arrives as
  ## `Customs_TarkovDev/Layers/SVG/Customs.svg?ident=1`, which does not end in
  ## `.svg`, and the whitelist below refuses a file that exists -- every map
  ## renders blank while the guard reports itself working correctly.
  var i = 0
  while i < s.len:
    if s[i] == '?' or s[i] == '#':
      return s.substr(0, i - 1)
    inc i
  result = s

proc okChar(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
  (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-'

proc safeRel*(rel: string; outRel: var string): bool =
  ## True only for a relative path of whitelisted segments ending in `.svg`.
  ## Refuses `.`/`..`, empty segments, backslashes, drive letters, anything
  ## with a character not on the whitelist, and anything over-long. A refusal
  ## here is a 404 with a reason, never a silent empty body.
  outRel = ""
  if rel.len == 0 or rel.len > 240: return false
  if not (rel.len > 4 and rel[rel.len-4] == '.' and rel[rel.len-3] == 's' and
          rel[rel.len-2] == 'v' and rel[rel.len-1] == 'g'): return false
  var seg = ""
  var segs = 0
  var i = 0
  while i <= rel.len:
    let atEnd = i == rel.len
    let c = if atEnd: '/' else: rel[i]
    if c == '/':
      if seg.len == 0: return false
      if seg == "." or seg == "..": return false
      inc segs
      if segs > 8: return false
      if outRel.len > 0: outRel.add "\\"
      outRel.add seg
      seg = ""
    elif okChar(c):
      seg.add c
    else:
      return false
    inc i
  result = segs > 0

# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------

proc errJson(reason: string): string =
  ## The ONE way an error leaves this file. `put` escapes, so a Windows path in
  ## `reason` cannot break the document.
  var o = obj()
  put(o, "err", reason)
  result = done(o).text

proc onIndex(url, body, session: string): string =
  if gIndexJson.len == 0:
    return errJson("no map index was loaded from " & gMapsRoot &
                   " -- the mod's data/ directory did not ship beside its library")
  result = gIndexJson

proc onMap(url, body, session: string): string =
  let id = stripQuery(pathAfter(url, MapPrefix))
  var rel = ""
  # A map id is one whitelisted segment; reuse the same guard by appending the
  # extension the whitelist demands rather than writing a second, weaker check.
  if not safeRel(id & ".svg", rel):
    return errJson("refused map id")
  var text = ""
  if not slurp(joinp(gMapsRoot, id & ".json"), text):
    return errJson("no such map: " & id)
  result = text

proc onAsset(url, body, session: string): string =
  let rel = stripQuery(pathAfter(url, AssetPrefix))
  var safe = ""
  if not safeRel(rel, safe):
    return "<svg xmlns=\"http://www.w3.org/2000/svg\"><!-- refused: the " &
           "requested asset path is not a whitelisted relative .svg path --></svg>"
  var text = ""
  if not slurp(joinp(gMapsRoot, safe), text):
    return "<svg xmlns=\"http://www.w3.org/2000/svg\"><!-- not found: " &
           safe & " --></svg>"
  result = text

proc snapshotPath(): string =
  joinp(dataDir(), SnapshotName)

const Sentinel = "\n#aowlspt-spatial-end"
  ## The tear guard.
  ##
  ## The obvious way to stop a reader seeing a half-written file is
  ## temp-then-rename. nimony's stdlib has no `moveFile` (checked: `std/dirs`
  ## exports `removeFile` and nothing else of the kind), so that route is not
  ## available and pretending otherwise would mean shipping a race.
  ##
  ## So the writer appends a sentinel and the READER checks for it. This is a
  ## property of the FINISHED file, not of our own write: a torn read cannot
  ## end in the sentinel, so it is detected and reported as a partial write
  ## rather than parsed into a plausible-looking snapshot with entities
  ## missing. A page that silently drew half a raid would be exactly the
  ## confidently-wrong answer this mod is careful about everywhere else.
  ##
  ## It does not make the write atomic. It makes a non-atomic write DETECTABLE,
  ## which is the achievable property.

proc writeSnapshot*(body: string; err: var string): bool =
  ## Called from the CLIENT half, on the mod's timer thread -- never Unity's.
  result = spill(snapshotPath(), body & Sentinel, err)

proc absentJson(reason: string): string =
  var o = obj()
  put(o, "state", "absent")
  put(o, "reason", reason)
  result = done(o).text

proc onFeed(url, body, session: string): string =
  var text = ""
  if not slurp(snapshotPath(), text):
    return absentJson("no snapshot file at " & snapshotPath() &
      ". The client half has never published: either the game is not running, " &
      "or this mod's client side is not loaded, or config.json `enabled` is " &
      "false. This is INCONCLUSIVE -- it is not 'you are not in a raid'.")
  if text.len == 0:
    return absentJson("the snapshot file is empty")
  # The tear check. Anything not ending in the sentinel was caught mid-write.
  if text.len <= Sentinel.len:
    return absentJson("the snapshot file is shorter than its own terminator " &
                      "-- a partial write was caught")
  var i = 0
  var tail = true
  while i < Sentinel.len:
    if text[text.len - Sentinel.len + i] != Sentinel[i]:
      tail = false
      break
    inc i
  if not tail:
    return absentJson("the snapshot was read while it was being written (its " &
                      "terminator is missing). INCONCLUSIVE -- retry; it is " &
                      "not 'no contacts'.")
  result = text.substr(0, text.len - Sentinel.len - 1)

proc onPage(url, body, session: string): string = PageHtml
proc onLib(url, body, session: string): string = LibJs

proc onStatus(url, body, session: string): string =
  var o = obj()
  put(o, "mapsRoot", gMapsRoot)
  put(o, "maps", gMapCount)
  put(o, "layers", gLayerCount)
  put(o, "snapshotPath", snapshotPath())
  put(o, "staleAfterMs", StaleAfterMs)
  put(o, "indexLoaded", gIndexJson.len > 0)
  result = done(o).text

# --------------------------------------------------------------------------
# Snapshot serialisation. Lives here, on the mod's timer thread, so that the
# Unity thread never builds a string.
# --------------------------------------------------------------------------

proc snapshotJson*(s: Snapshot; stateText, defect: string; faults: int;
                   disabled: bool; radius: float): string =
  var o = obj()
  # `state` is the FOUR-way answer, not a bool. A page that cannot tell "no
  # host export" from "not in a raid" will draw an empty map for both and
  # imply the second.
  put(o, "state", (case s.state
                   of 3: "live"
                   of 2: "armed-no-world"
                   of 1: "not-armed"
                   of 0: "no-host-export"
                   else: "self-disabled"))
  put(o, "stateText", stateText)
  put(o, "inRaid", s.inRaid)
  # The raid's map KEY (GameWorld.LocationId), so the browser view can select
  # the calibrated map by name via index.json's internalNames instead of the
  # bounds guess that put Lighthouse art on Woods (bug 2). Empty when unread.
  put(o, "locationId", s.locationId)
  # Spawned-and-in-world THIS collection: the browser can distinguish an active
  # raid from a stale borrowed cache (bug 1) exactly as the in-game HUD does.
  put(o, "localAlive", s.localAlive)
  put(o, "ok", s.ok)
  put(o, "seq", int(s.seq))
  put(o, "faults", faults)
  put(o, "disabled", disabled)
  put(o, "defect", defect)
  put(o, "radiusM", radius)
  # Always false today. The page reads THIS, not a default, and draws
  # north-up with a visible note when it is false -- so a heading that is not
  # measured can never be silently rendered as heading zero.
  put(o, "hasHeading", s.hasHeading)
  put(o, "heading", s.heading)
  put(o, "localIdx", s.localIdx)
  var a = arr()
  var i = 0
  while i < s.n:
    var e = obj()
    # World (x, y, z): y is UP in Unity. The map plane is (x, z); `y` is kept
    # so the page can pick the right map LEVEL. Names are the world's, so no
    # axis convention is baked in here -- the swap happens once, in the page,
    # where it is written down.
    put(e, "x", s.ents[i].x)
    put(e, "y", s.ents[i].y)
    put(e, "z", s.ents[i].z)
    put(e, "bot", s.ents[i].bot)
    put(e, "me", s.ents[i].me)
    # The CLASS, plus the two RAW enum values it was derived from. The raws are
    # served deliberately: `cls` is this mod's opinion, `side`/`role` are what
    # the client actually said, and a reader who thinks the classifier is wrong
    # can check it without a rebuild. Both are -1 when the read declined, which
    # is distinct from any value either enum defines.
    put(e, "cls", s.ents[i].cls)
    put(e, "clsName", clsName(s.ents[i].cls))
    put(e, "side", int(s.ents[i].side))
    put(e, "role", int(s.ents[i].role))
    put(e, "id", s.ents[i].id)
    a.add done(e)
    inc i
  put(o, "ents", done(a))
  # The per-collection histogram, alongside the entities it summarises, so the
  # page can show the distribution without recounting (and so a diff of the two
  # would catch a serialiser that drops entities).
  var h = obj()
  var hi = 0
  while hi < ClsCount:
    put(h, clsName(hi), s.cls[hi])
    inc hi
  put(o, "classHistogram", done(h))
  put(o, "classVerdict", clsVerdict())
  result = done(o).text

# --------------------------------------------------------------------------
# Load
# --------------------------------------------------------------------------

proc registerRoutes*(why: var string): bool =
  why = ""
  gMapsRoot = joinp(joinp(modDir(), "data"), "maps")
  var idx = ""
  if slurp(joinp(gMapsRoot, "index.json"), idx):
    gIndexJson = idx
    # The counts come out of the document's own `mapCount`/`totalLayers`, which
    # the vendoring step writes.
    #
    # They used to be derived by counting `"id":` and `"laye` substrings. That
    # is the shape of check this repo keeps getting burned by: it reported
    # `layers: 11` -- one per map, because the SUMMARY key `"layers"` occurs
    # once per entry -- when the true figure is 36. It could not have reported
    # anything else, and it looked entirely plausible. Reading the number the
    # generator computed is falsifiable: if the field is missing, the count is
    # 0 and the load line says the index is malformed rather than inventing a
    # number from the file's punctuation.
    gMapCount = asInt(field(idx, "mapCount"), 0)
    gLayerCount = asInt(field(idx, "totalLayers"), 0)
  else:
    why = "no map index at " & joinp(gMapsRoot, "index.json") &
          " -- the mod's data/ directory did not ship beside its library, so " &
          "the routes are registered but every asset will 404"

  var bad = 0
  if serve(IndexRoute, onIndex) != Ok: inc bad
  if serve(FeedRoute, onFeed) != Ok: inc bad
  if serve(StatusRoute, onStatus) != Ok: inc bad
  if servePrefix(MapPrefix, onMap) != Ok: inc bad
  if servePrefix(AssetPrefix, onAsset) != Ok: inc bad
  # The draw surface. Same two-route shape as `mods/uihub`: a thin page shell
  # plus the library it is built out of, so a third-party page can load the
  # identical client instead of reimplementing these views and drifting.
  if serve(LibRoute, onLib) != Ok: inc bad
  if serve(PageRoute, onPage) != Ok: inc bad
  if bad > 0:
    why = $bad & " of 7 map routes did not register"
    return false
  result = why.len == 0
