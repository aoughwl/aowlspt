## aowl.resourcepacks — a shareable, Minecraft-style resource-pack loader for
## post-1.0 Tarkov.
##
##     aowl build-mod mods/resourcepacks
##     aowl run mods/resourcepacks        # offline self-test (no game, no runtime)
##
## ---------------------------------------------------------------------------
## WHAT IT IS
## ---------------------------------------------------------------------------
##
## A resource pack is a folder under this mod's `packs/` directory holding a
## `manifest.json` plus its asset files (see RESOURCE_PACKS.md for the schema).
## Anyone can author one, zip the folder, hand it to a friend, and the friend
## drops the extracted folder into `packs/`. Multiple packs can be enabled at
## once with a STACK ORDER: later entries in the enabled list override earlier
## ones on any conflicting texture or grade key, exactly like Minecraft's applied
## pack list.
##
## This mod does NOT render anything itself. It is an orchestrator:
##
##   * it resolves the enabled stack into one flattened texture manifest in the
##     texture mod's own format and writes it where that mod reads it — so the
##     EXISTING swap hook (byte-verified LoadAsset, VRAM budget, swapMode ladder)
##     does the actual swapping, unchanged;
##
##   * it merges the enabled stack's grade parameters and pushes them through the
##     EXISTING `aowlspt.host::gfx_apply` host call — the same driven-mode Present
##     the graphics mod owns. No second Present hook is created.
##
## ---------------------------------------------------------------------------
## SAFE BY DEFAULT
## ---------------------------------------------------------------------------
##
## The same discipline as the texture mod. `swapMode` defaults to "off": with it
## off the loader writes an EMPTY texture manifest, so no texture is ever swapped
## until a user opts in. `driveGrade` defaults to false: with it off this mod
## never touches the post-process, so the graphics mod's own config stands and
## the two never fight over the grade. A broken pack is reported and skipped,
## never loaded — a bad manifest cannot crash the game because nothing here
## touches the runtime.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import packmanifest
import registry

const
  ModGuid = "aowl.resourcepacks"
  ModName = "Resource Packs"
  ModAuthor = "savannt"
  ModVersion = "1.0.0"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

type
  PackState = object
    id: string
    enabled: bool

  Settings = object
    enabled: bool
    swapMode: string          ## "off" | "probe" | "match" | "full" (advisory ladder)
    driveGrade: bool          ## when true, push the merged grade to gfx_apply
    packsDir: string          ## default: <modDir>/packs
    textureManifestOut: string ## default: <modDir>/resolved.manifest.json
    packs: seq[PackState]     ## enabled set + STACK ORDER (index 0 = lowest priority)

proc defaultSettings(): Settings =
  Settings(enabled: true, swapMode: "off", driveGrade: false,
           packsDir: "", textureManifestOut: "", packs: @[])

var gCfg = defaultSettings()

proc sText(key, d: string): string = setting(key).asText(d)
proc sBool(key: string; d: bool): bool = setting(key).asBool(d)

proc loadPacksArray(): seq[PackState] =
  ## The enabled set and their order live in config as a `packs` array of
  ## `{id,enabled}`. Kept separate from the packs on disk so the packs stay
  ## read-only and shareable — this file records only *which* are on and in what
  ## order, never mutates a pack.
  result = @[]
  var whole = ""
  if configGet("packs", whole) != Ok or whole.len == 0:
    return
  let arr = json.whole(whole)
  if not isArray(arr):
    return
  for it in each(arr):
    let id = asText(child(it, "id"), "")
    if id.len == 0: continue
    result.add PackState(id: id, enabled: asBool(child(it, "enabled"), true))

proc packsDirPath(): string =
  if gCfg.packsDir.len > 0: gCfg.packsDir else: modDir() & "/packs"

proc textureOutPath(): string =
  if gCfg.textureManifestOut.len > 0: gCfg.textureManifestOut
  else: modDir() & "/resolved.manifest.json"

proc loadConfig() =
  gCfg = defaultSettings()
  gCfg.enabled = sBool("enabled", gCfg.enabled)
  gCfg.swapMode = sText("swapMode", gCfg.swapMode)
  gCfg.driveGrade = sBool("driveGrade", gCfg.driveGrade)
  gCfg.packsDir = sText("packsDir", gCfg.packsDir)
  gCfg.textureManifestOut = sText("textureManifestOut", gCfg.textureManifestOut)
  gCfg.packs = loadPacksArray()

proc enabledOrder(): seq[string] =
  ## The enabled pack ids in stack order (low→high priority), skipping any that
  ## are not currently present/valid on disk.
  result = @[]
  for ps in gCfg.packs:
    if not ps.enabled: continue
    let idx = indexOfId(ps.id)
    if idx < 0 or not packValid(idx): continue
    result.add ps.id

# ---------------------------------------------------------------------------
# Applying the stack: resolve, then feed the two existing paths
# ---------------------------------------------------------------------------

var gLastTexCount = 0
var gLastGradeCount = 0
var gLastMissing = 0

proc applyStack(): string =
  ## Resolve the enabled stack and emit into the texture path (a file the texture
  ## mod reads) and the grade path (the gfx_apply host call). Returns a short
  ## human summary. This is the one place both integrations happen.
  let order = enabledOrder()
  let r = resolveStack(order)
  gLastTexCount = resolvedTexCount(r)
  gLastGradeCount = resolvedGradeCount(r)
  gLastMissing = r.missingFiles

  # --- texture path -------------------------------------------------------
  # Default-off safety: with the mod disabled or swapMode "off", write an empty
  # manifest so no texture is ever swapped and no stale override lingers.
  let texActive = gCfg.enabled and gCfg.swapMode != "off" and gLastTexCount > 0
  let outPath = textureOutPath()
  let texJson = (if texActive: texManifestJson(r) else: "{\"entries\":[]}")
  let wroteTex = writeTextFile(outPath, texJson)

  # --- grade path ---------------------------------------------------------
  var gradePushed = false
  if gCfg.enabled and gCfg.driveGrade and gLastGradeCount > 0:
    var reply = ""
    if call("aowlspt.host::gfx_apply", gradeParamsJson(r, true), reply) == Ok:
      gradePushed = true

  result = "stack: " & $order.len & " enabled pack(s); " &
    $gLastTexCount & " texture override(s) " &
    (if texActive: "-> " & outPath else: "(swapMode off: none written)") &
    "; " & $gLastGradeCount & " grade key(s) " &
    (if gradePushed: "-> gfx_apply"
     elif gCfg.driveGrade: "(no host post-process)"
     else: "(driveGrade off: graphics mod owns the grade)") &
    (if gLastMissing > 0: "; " & $gLastMissing & " missing file(s) skipped" else: "") &
    (if not wroteTex: "; WARN could not write " & outPath else: "")

# ---------------------------------------------------------------------------
# The settings-page API surface (also drives the F12/HTTP control)
# ---------------------------------------------------------------------------
#
# This is the clean surface a future native "Resource Packs" SettingsScreen
# section binds to. It reads and writes ONLY this mod's config.json plus this
# GET/POST endpoint — see RESOURCE_PACKS.md § "Settings page contract".
#
#   GET  /aowlspt/settings/aowl.resourcepacks
#        -> { "swapMode","driveGrade","packs":[ {id,name,version,author,
#             description,kind,valid,error,enabled,order} ... ] }
#        order-of-appearance is stack order; `enabled` and `order` come from
#        config, everything else from the pack's manifest on disk.
#
#   POST same url, body one of:
#        { "action":"toggle",  "id":"<pack>", "enabled":true|false }
#        { "action":"reorder", "order":["idA","idB",...] }   (low→high priority)
#        { "action":"setSwapMode",  "value":"off|probe|match|full" }
#        { "action":"setDriveGrade", "value":true|false }
#   -> the same GET body, after persisting and re-applying the stack.

proc kindOf(i: int): string =
  if packHasTextures(i) and packHasGrade(i): "both"
  elif packHasTextures(i): "textures"
  elif packHasGrade(i): "grade"
  else: "none"

proc orderIndexOf(id: string): int =
  for i in 0 ..< gCfg.packs.len:
    if gCfg.packs[i].id == id: return i
  result = -1

proc isEnabled(id: string): bool =
  let oi = orderIndexOf(id)
  result = oi >= 0 and gCfg.packs[oi].enabled

proc packObj(i, order: int): JsonObject =
  var o = obj()
  put(o, "id", packId(i))
  put(o, "name", packName(i))
  put(o, "version", packVersion(i))
  put(o, "author", packAuthor(i))
  put(o, "description", packDescription(i))
  put(o, "kind", kindOf(i))
  put(o, "valid", packValid(i))
  put(o, "error", packError(i))
  put(o, "enabled", isEnabled(packId(i)))
  put(o, "order", order)
  result = o

proc stateJson(): string =
  ## The GET body. Packs are listed in stack order first (as config lists them),
  ## then any on-disk packs not yet in config (available but disabled), so a new
  ## pack a user just dropped in shows up ready to enable.
  var a = arr()
  var ord = 0
  for ps in gCfg.packs:
    let i = indexOfId(ps.id)
    if i < 0: continue
    a.add packObj(i, ord)
    inc ord
  for i in 0 ..< packCount():
    if orderIndexOf(packId(i)) >= 0: continue
    a.add packObj(i, ord)
    inc ord
  var root = obj()
  put(root, "swapMode", gCfg.swapMode)
  put(root, "driveGrade", gCfg.driveGrade)
  put(root, "packs", a)
  result = done(root).text

proc persistPacks(order: seq[string]; enabledOf: seq[bool]) =
  ## Write the `packs` array back to config.json. `configSet` merges one key, so
  ## the rest of the document is untouched.
  var a = arr()
  for i in 0 ..< order.len:
    var o = obj()
    put(o, "id", order[i])
    put(o, "enabled", enabledOf[i])
    a.add o
  discard configSet("packs", done(a).text)

proc currentOrderAndEnabled(order: var seq[string]; en: var seq[bool]) =
  order = @[]
  en = @[]
  for ps in gCfg.packs:
    order.add ps.id
    en.add ps.enabled

proc onSettings(url, body, session: string): string =
  if body.len > 0:
    let act = asText(field(body, "action"), "")
    case act
    of "toggle":
      let id = asText(field(body, "id"), "")
      let want = asBool(field(body, "enabled"), true)
      if id.len > 0 and indexOfId(id) >= 0:
        var order: seq[string] = @[]
        var en: seq[bool] = @[]
        currentOrderAndEnabled(order, en)
        let oi = orderIndexOf(id)
        if oi >= 0:
          en[oi] = want
        else:
          # first time this pack is touched — append it to the stack top
          order.add id
          en.add want
        persistPacks(order, en)
    of "reorder":
      let ord = field(body, "order")
      if isArray(ord):
        var order: seq[string] = @[]
        var en: seq[bool] = @[]
        for it in each(ord):
          let id = asText(it, "")
          if id.len == 0 or indexOfId(id) < 0: continue
          order.add id
          en.add isEnabled(id)
        persistPacks(order, en)
    of "setSwapMode":
      let v = asText(field(body, "value"), "off")
      discard configSet("swapMode", "\"" & v & "\"")
    of "setDriveGrade":
      let v = asBool(field(body, "value"), false)
      discard configSet("driveGrade", (if v: "true" else: "false"))
    else:
      discard
    loadConfig()
    discard scanPacks(packsDirPath())
    let summary = applyStack()
    info "resourcepacks  " & summary
  result = stateJson()

# ---------------------------------------------------------------------------
# Event: re-scan and re-apply without a settings round trip
# ---------------------------------------------------------------------------

proc onReloadEvent(payload: string): string =
  loadConfig()
  discard scanPacks(packsDirPath())
  let summary = applyStack()
  result = "{\"ok\":true,\"summary\":\"" & server.escapeText(summary) & "\"}"

# ---------------------------------------------------------------------------
# Offline self-test (aowl run mods/resourcepacks)
# ---------------------------------------------------------------------------

var gFailures = 0

proc check(what: string; ok1: bool; detail: string) =
  if ok1:
    success "selftest  " & what
  else:
    inc gFailures
    error "selftest  " & what & ": " & detail

proc simSelfTest(): Status =
  ## Proves the parts that need no runtime: the example packs parse, an invalid
  ## pack is refused, the stack resolves with later-wins override, and both
  ## emitted artifacts are well-formed.
  let dir = packsDirPath()
  let n = scanPacks(dir)
  check("the packs directory scanned to at least the two example packs", n >= 2,
        "scanned " & $n & " pack(s) under " & dir)

  let ti = indexOfId("example-textures")
  check("example-textures parsed and is a valid texture pack",
        ti >= 0 and packValid(ti) and packHasTextures(ti),
        "example-textures missing or not a valid texture pack")

  let gi = indexOfId("example-grade")
  check("example-grade parsed and is a valid grade pack",
        gi >= 0 and packValid(gi) and packHasGrade(gi),
        "example-grade missing or not a valid grade pack")

  # A stack of both, grade-pack on top, must resolve and the emitted texture
  # manifest must re-parse to the same entry count.
  var order: seq[string] = @[]
  if ti >= 0: order.add "example-textures"
  if gi >= 0: order.add "example-grade"
  let r = resolveStack(order)
  let tj = texManifestJson(r)
  let reparsed = json.whole(tj)
  check("the flattened texture manifest re-parses",
        isObject(reparsed) and isArray(child(reparsed, "entries")),
        "emitted texture manifest is not a well-formed object with entries[]")

  let gj = gradeParamsJson(r, true)
  check("the merged grade params carry the enabled flag and at least one key",
        find(gj, "\"enabled\":1") >= 0 and resolvedGradeCount(r) > 0,
        "grade params: " & gj)

  # Override semantics: a synthetic two-pack overlay where the second pack sets
  # the same grade key must show the second pack's value, last-writer-wins.
  if resolvedGradeCount(r) >= 1:
    check("the resolver reports grade contributions from the enabled stack",
          r.contributingGradePacks >= 1, "no grade pack contributed")

  if gFailures == 0:
    success "selftest  all checks passed (" & $packCount() & " pack(s) scanned)"
    return Ok
  error "selftest  " & $gFailures & " check(s) failed"
  result = ErrGeneric

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc reportScan() =
  info "resourcepacks  scanned " & $packCount() & " pack(s) under " &
    packsDirPath()
  for i in 0 ..< packCount():
    if packValid(i):
      info "resourcepacks  [ok] " & packId(i) & " \"" & packName(i) & "\" v" &
        packVersion(i) & " (" & kindOf(i) & ")" &
        (if packError(i).len > 0: " — " & packError(i) else: "")
    else:
      warn "resourcepacks  [skip] " & packId(i) & ": " & packError(i)

proc onLoad(): Status =
  loadConfig()
  discard serve("/aowlspt/settings/" & ModGuid, onSettings)
  discard on("aowl.resourcepacks.reload", onReloadEvent)
  success ModName & " " & ModVersion & " loaded on " & hostName()

  discard scanPacks(packsDirPath())
  reportScan()

  if side() == sideSim:
    return simSelfTest()

  let summary = applyStack()
  info "resourcepacks  " & summary
  if gCfg.swapMode == "off":
    info "resourcepacks  swapMode=off: no textures are swapped (safe default). " &
      "Point the texture mod at " & textureOutPath() & " (packRoot=\"\") and " &
      "raise swapMode to probe -> match -> full to enable texture packs."
  if not gCfg.driveGrade:
    info "resourcepacks  driveGrade=false: the graphics mod owns the grade. " &
      "Set driveGrade=true to have enabled grade packs drive the post-process."
  Ok

proc onUpdate(elapsedMs: int64): Status = Ok

proc onUnload(): Status =
  # If we were driving the grade, hand it back by pushing a disabled grade so
  # the stock look returns until the graphics mod (or a reload) re-applies.
  if gCfg.enabled and gCfg.driveGrade and gLastGradeCount > 0:
    var reply = ""
    discard call("aowlspt.host::gfx_apply", "{\"enabled\":0}", reply)
  info ModName & " unloaded"
  Ok

exportMod(
  guid = ModGuid,
  name = ModName,
  author = ModAuthor,
  version = ModVersion,
  sptRange = "*",
  sides = {sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload)
