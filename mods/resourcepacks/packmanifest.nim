## packmanifest.nim — parse and validate one resource pack's `manifest.json`.
##
## A resource pack is a folder under the mod's `packs/` directory (Minecraft
## style): a `manifest.json` beside the asset files it ships. This module reads
## one such manifest and hands back a `Pack` record with `valid`/`error` set,
## the same fail-safe posture the texture mod holds: a broken pack is *reported
## and skipped*, never a crash. Nothing here touches the runtime, hooks nothing,
## and allocates only strings — it is pure parsing.
##
## The schema is documented in RESOURCE_PACKS.md; the validator below is its
## executable copy. Two capability kinds exist:
##
##   * "textures" — a list of `{name,file,map,cat,tier,conf}` overrides, in the
##     exact shape the texture mod's `manifest.nim` already reads, so the
##     resolved stack drops straight into that swap path.
##   * "grade"    — a flat object of post-process parameters (a subset of the
##     graphics mod's grade keys) and/or a `lut` image, pushed through the
##     existing `gfx_apply` host call.

import std/syncio
import aowlspt/json

type
  TexOv* = object
    name*: string   ## lowercased Unity texture name — the swap lookup key
    file*: string   ## replacement image path, RELATIVE to the pack root
    map*: string    ## "albedo" | "normal" | "roughness" | "ao" | ...
    cat*: string    ## free-form category tag (Metal, Wood, …)
    tier*: string   ## "2K" | "4K"
    conf*: float    ## author-declared match confidence 0..1

  Pack* = object
    id*: string           ## the folder name — the stable identity in config
    root*: string         ## absolute path to the pack folder
    name*: string
    version*: string
    author*: string
    description*: string
    hasTextures*: bool
    hasGrade*: bool
    textures*: seq[TexOv]
    gradeKeys*: seq[string]  ## grade parameter names …
    gradeVals*: seq[string]  ## … and their raw JSON values (parallel arrays)
    gradeLut*: string        ## optional LUT image path, relative to root ("" = none)
    valid*: bool
    error*: string           ## why it is invalid, when it is; "" otherwise

const
  SchemaId* = "aowlspt.resourcepack"
  SchemaVersion* = 1

  ## The grade keys a pack may set. Anything else in its `grade` object is
  ## ignored (reported, not fatal). These match the graphics mod's flat params
  ## exactly, so a merged grade is pushed verbatim through `gfx_apply`.
  GradeKeys* = [
    "tonemapper", "tonemapStrength", "exposure", "contrast", "saturation",
    "temperature", "tint", "lift", "gamma", "gain", "shadows", "highlights",
    "sharpness", "bloom", "bloomStrength", "vignette", "vignetteRadius"]

proc lowerAscii(s: string): string =
  result = newString(s.len)
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result[i] = chr(ord(c) + 32)
    else:
      result[i] = c

proc readWholeFile(path: string; into: var string): bool =
  ## Non-raising whole-file read (the bool `open` overload does not raise).
  var f: File
  if not open(f, path, fmRead):
    return false
  into = ""
  var line = ""
  var first = true
  while readLine(f, line):
    if not first: into.add "\n"
    into.add line
    first = false
  close(f)
  result = true

proc isKnownGradeKey(k: string): bool =
  for g in GradeKeys:
    if g == k: return true
  result = false

proc badPack(id, root, why: string): Pack =
  ## An invalid pack, carrying the reason. Valid packs are the only ones the
  ## registry ever flattens, so this is the whole skip path.
  Pack(id: id, root: root, name: id, version: "", author: "", description: "",
       hasTextures: false, hasGrade: false, textures: @[], gradeKeys: @[],
       gradeVals: @[], gradeLut: "", valid: false, error: why)

proc parsePack*(id, root: string): Pack =
  ## Read `<root>/manifest.json` and validate it. `id` is the folder name (the
  ## config identity); `root` its absolute path. Always returns a `Pack` — check
  ## `.valid` and, when false, `.error`.
  let mpath = root & "/manifest.json"
  var text = ""
  if not readWholeFile(mpath, text) or text.len == 0:
    return badPack(id, root, "no readable manifest.json in the pack folder")

  let doc = whole(text)
  if not doc.exists or not isObject(doc):
    return badPack(id, root, "manifest.json is not a JSON object")

  if asText(child(doc, "schema"), "") != SchemaId:
    return badPack(id, root, "schema is not \"" & SchemaId & "\" (got \"" &
                   asText(child(doc, "schema"), "") & "\")")
  let sv = asInt(child(doc, "schemaVersion"), 0)
  if sv != SchemaVersion:
    return badPack(id, root, "schemaVersion " & $sv & " is unsupported (this " &
                   "build reads " & $SchemaVersion & ")")

  var p = Pack(
    id: id, root: root,
    name: asText(child(doc, "name"), id),
    version: asText(child(doc, "version"), ""),
    author: asText(child(doc, "author"), ""),
    description: asText(child(doc, "description"), ""),
    hasTextures: false, hasGrade: false,
    textures: @[], gradeKeys: @[], gradeVals: @[], gradeLut: "",
    valid: true, error: "")

  if p.name.len == 0:
    return badPack(id, root, "name is required and must be non-empty")
  if p.version.len == 0:
    return badPack(id, root, "version is required and must be non-empty")

  # Capabilities declare what the pack ships. They are advisory — the presence
  # of a valid `textures` array or `grade` object is what actually arms each
  # path — but a declared capability with no matching payload is a warning the
  # registry surfaces, and an empty capability set is refused.
  let caps = child(doc, "capabilities")
  var declaredTex = false
  var declaredGrade = false
  if caps.exists and isArray(caps):
    for c in each(caps):
      let cn = asText(c, "")
      if cn == "textures": declaredTex = true
      elif cn == "grade": declaredGrade = true

  # ---- textures ----------------------------------------------------------
  let tex = child(doc, "textures")
  if tex.exists and isArray(tex):
    for it in each(tex):
      let nm = lowerAscii(asText(child(it, "name"), ""))
      let fl = asText(child(it, "file"), "")
      if nm.len == 0 or fl.len == 0:
        continue   # a nameless or fileless entry is dropped, pack still valid
      p.textures.add TexOv(
        name: nm, file: fl,
        map:  asText(child(it, "map"), "albedo"),
        cat:  asText(child(it, "cat"), ""),
        tier: asText(child(it, "tier"), "2K"),
        conf: asFloat(child(it, "conf"), 1.0))
    p.hasTextures = p.textures.len > 0

  # ---- grade -------------------------------------------------------------
  let grade = child(doc, "grade")
  if grade.exists and isObject(grade):
    for k in keys(grade):
      if k == "lut":
        p.gradeLut = asText(child(grade, "lut"), "")
        continue
      if not isKnownGradeKey(k):
        continue   # unknown grade key ignored, not fatal
      p.gradeKeys.add k
      p.gradeVals.add raw(child(grade, k))
    p.hasGrade = p.gradeKeys.len > 0 or p.gradeLut.len > 0

  if not p.hasTextures and not p.hasGrade:
    return badPack(id, root, "the pack ships neither a usable textures array " &
                   "nor a grade object — nothing to load")

  # A declared capability with no payload is worth saying, but not fatal.
  if declaredTex and not p.hasTextures:
    p.error = "note: declares \"textures\" but ships no usable texture entries"
  if declaredGrade and not p.hasGrade:
    p.error = "note: declares \"grade\" but ships no usable grade parameters"

  result = p
