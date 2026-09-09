## A FIXTURE, not a shipped mod. It exists to answer one question with
## evidence: does the settings surface -- the schema in `aowlspt/settings`, the
## `/aowlspt/settings/*` routes, and the client in `mods/uihub` -- actually hold
## up at the scale `mods/tarkov` is heading for?
##
## So it declares 264 settings across 8 categories and 3 subcategories each,
## every control type including the two large-enumeration shapes:
##
##   * `itemInline`  -- a `select` with 900 choices SHIPPED IN THE SCHEMA, with
##     `optionLabels` giving each id a display name.
##   * `itemRemote`  -- a `select` with NO inline options and an `optionsUrl`,
##     the shape a mod with thousands of item ids should use. The route it
##     names is implemented below and is the reference implementation of that
##     contract: `GET <optionsUrl>?q=<term>&limit=<n>` ->
##     `{"options":[{"value","label"}...]}`.
##
## It is deliberately NOT under `mods/`, so `aowl build mods` does not build it
## and no release can ship it by accident. Build and run it on purpose:
##
##     aowl build-mod tests\uihubscale
##     copy tests\uihubscale\bin\uihubscale.dll <a scratch root>\mods\uihubscale\
##
## then point a browser (or curl) at that root's backend.

import std/strutils
import aowlspt
import aowlspt/server as sv
import aowlspt/settings

const
  ModGuid = "aowl.uihubscale"
  ModName = "UI scale fixture"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

  Cats = ["General", "Combat", "Economy", "Bots", "Loot", "Weather",
          "Quests", "Diagnostics"]
  Subs = ["Core", "Tuning", "Experimental"]

proc itemId(i: int): string =
  ## A fake but item-id-shaped identifier, so the typeahead is exercised
  ## against strings that look like the real thing rather than "opt3".
  result = "5" & $(447200 + i * 7) & "a1b2c"

proc itemName(i: int): string =
  const Adj = ["Rusty", "Pristine", "Modded", "Trader", "Rare", "Common"]
  const Noun = ["magazine", "helmet", "scope", "backpack", "rig", "barrel",
                "stock", "canteen", "battery", "keycard"]
  result = Adj[i mod 6] & " " & Noun[i mod 10] & " #" & $i

proc bigOptions(): seq[string] =
  result = @[]
  for i in 0 ..< 900:
    result.add itemId(i)

proc bigLabels(): seq[string] =
  result = @[]
  for i in 0 ..< 900:
    result.add itemName(i)

proc fixtureSchema(): seq[Setting] =
  result = @[]
  var n = 0
  for c in Cats:
    for s in Subs:
      for j in 0 ..< 11:
        let key = "k" & $n
        let lab = c & " " & s & " option " & $j
        let desc = "fixture row " & $n & " in " & c & " / " & s
        case j
        of 0, 1, 2:
          result.add boolSetting(key, lab, j == 1, category = c,
                                 subcategory = s, description = desc)
        of 3, 4:
          result.add intSetting(key, lab, 5, lo = 0, hi = 100, step = 1,
                                category = c, subcategory = s, description = desc)
        of 5:
          result.add intSetting(key, lab, 5, category = c, subcategory = s,
                                description = desc & " (no range declared)")
        of 6, 7:
          result.add floatSetting(key, lab, 1.0, lo = 0.0, hi = 4.0, step = 0.05,
                                  category = c, subcategory = s, description = desc)
        of 8:
          result.add enumSetting(key, lab, "auto", @["auto", "manual", "off"],
                                 category = c, subcategory = s, description = desc)
        of 9:
          result.add stringSetting(key, lab, "text", category = c,
                                   subcategory = s, description = desc)
        else:
          result.add keybindSetting(key, lab, "M", category = c, subcategory = s,
                                    description = desc, implemented = false)
        n = n + 1
  result.add selectSetting("itemInline", "Item (900 shipped inline)",
                           itemId(0), bigOptions(), bigLabels(),
                           category = "Loot", subcategory = "Core",
                           description = "a select whose choices ship in the schema")
  var noInline: seq[string] = @[]
  # --- ARBITRARY DEPTH ----------------------------------------------------
  #
  # Depth beyond two is expressed by putting separators IN `category` (see
  # `settingPath` in `aowl/src/aowlspt/settings.nim`), so no builder signature
  # changed and no mod that already declares settings had to be touched. These
  # twelve rows sit at depths 3 and 4 -- including the exact
  # "Player > Health > Regeneration" shape the report asked for -- and one row
  # deliberately carries a stray separator, because "A//B" must mean ["A","B"]
  # and must NOT produce a group with no name.
  for j in 0 ..< 5:
    result.add boolSetting("deepRegen" & $j, "Regen tick " & $j, j == 0,
                           category = "Deep/Player/Health/Regeneration",
                           description = "depth 4")
  for j in 0 ..< 4:
    result.add boolSetting("deepBleed" & $j, "Bleeding rule " & $j, false,
                           category = "Deep/Player/Health",
                           subcategory = "Damage/Bleeding",
                           description = "depth 5, split across both fields")
  for j in 0 ..< 2:
    result.add floatSetting("deepMove" & $j, "Inertia " & $j, 1.0,
                            lo = 0.0, hi = 2.0, step = 0.05,
                            category = "Deep/Player/Movement",
                            description = "depth 3")
  result.add boolSetting("deepStray", "Stray separators", true,
                         category = "Deep//Player///Movement/",
                         description = "empty segments must collapse, not " &
                                       "become a nameless group")

  result.add selectSetting("itemRemote", "Item (searched on the server)",
                           "", noInline,
                           optionsUrl = "/aowlspt/settings/aowl.uihubscale/items",
                           category = "Loot", subcategory = "Core",
                           description = "a select that fetches its choices as you type")

proc onSettings(url, body, session: string): string =
  var st = Ok
  if body.len > 0:
    st = applySettingFromBody(body)
  result = declaredSchemaReply(st).text

proc onReset(url, body, session: string): string =
  result = declaredSchemaReply(resetFromBody(body)).text

proc queryValue(url, name: string): string =
  ## One `?name=value` out of a url, percent-decoded. Same shape as
  ## `mods/tarkov`'s own `queryValue`; duplicated rather than imported because
  ## a fixture must not make another mod's private helper public.
  var at = find(url, "?" & name & "=")
  if at < 0:
    at = find(url, "&" & name & "=")
  if at < 0:
    return ""
  var i: int = at + name.len + 2
  var enc = ""
  while i < url.len and url[i] != '&':
    enc.add url[i]
    inc i
  result = ""
  var j = 0
  while j < enc.len:
    let ch = enc[j]
    if ch == '+':
      result.add ' '
      inc j
    elif ch == '%' and j + 2 < enc.len:
      var v = 0
      var good = true
      for k in 1 .. 2:
        let d = enc[j + k]
        if d >= '0' and d <= '9': v = v * 16 + (int(d) - int('0'))
        elif d >= 'a' and d <= 'f': v = v * 16 + (int(d) - int('a') + 10)
        elif d >= 'A' and d <= 'F': v = v * 16 + (int(d) - int('A') + 10)
        else: good = false
      if good:
        result.add char(v)
        j = j + 3
      else:
        result.add ch
        inc j
    else:
      result.add ch
      inc j

proc lowerAscii(s: string): string =
  result = ""
  for ch in s:
    if ch >= 'A' and ch <= 'Z': result.add char(int(ch) + 32)
    else: result.add ch

proc containsFold(hay, needle: string): bool =
  ## Case-insensitive substring. Written out because the search a `select`
  ## does must not depend on the caller having lower-cased its term.
  result = find(lowerAscii(hay), lowerAscii(needle)) >= 0

proc parseIntOr(s: string; default: int): int =
  result = 0
  if s.len == 0: return default
  for ch in s:
    if ch < '0' or ch > '9': return default
    result = result * 10 + (int(ch) - int('0'))

proc onItems(url, body, session: string): string =
  ## The reference `optionsUrl` implementation. Matches on both the id and the
  ## display name, caps at `limit`, and reports the total it matched, so a UI
  ## can say "showing the first n" honestly instead of implying the list is
  ## complete.
  let want = queryValue(url, "q")
  var limit = 50
  let lim = queryValue(url, "limit")
  if lim.len > 0:
    let n = parseIntOr(lim, 50)
    if n > 0 and n <= 200: limit = n
  var a = arr()
  var matched = 0
  for i in 0 ..< 4000:
    let id = itemId(i)
    let nm = itemName(i)
    if want.len == 0 or containsFold(id, want) or containsFold(nm, want):
      matched = matched + 1
      if matched <= limit:
        var o = obj()
        o.put("value", id)
        o.put("label", nm)
        a.add o
  var root = obj()
  root.put("options", a)
  root.put("matched", matched)
  result = done(root).text

proc onLoad(): Status =
  if side() != sideServer:
    info ModName & " is a server-side fixture; nothing to do on this side"
    return Ok
  declareSettings(fixtureSchema())
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard serve("/aowlspt/settings/" & ModGuid & "/reset", onReset)
  discard serve("/aowlspt/settings/" & ModGuid & "/items", onItems)
  success ModName & " " & ModVersion & " declared " &
          $declaredSettings().len & " settings"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideServer},
  onLoad = onLoad)
