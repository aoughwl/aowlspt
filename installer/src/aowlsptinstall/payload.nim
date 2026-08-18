## What the installer installs.
##
## The installer does not carry a game runtime inside itself, and it does not
## download one. It installs from a **payload directory**: a folder holding the
## pieces that go over the top of a Tarkov install, plus a manifest saying what
## Tarkov those pieces were built for.
##
## That indirection is the whole design. It means the thing deciding "is this
## safe to install onto that client" is reading a declaration rather than
## guessing, it means a payload for a newer Tarkov drops in without touching
## this program, and it means the installer never has to be the component that
## acquires game files.
##
## Layout:
##
##     payload/
##       payload.json        the manifest -- required
##       runtime/            copied to <target>/           (SPT_Runtime, ...)
##       client/             copied to <target>/           (BepInEx, doorstop)
##       aowlspt/            copied to <target>/aowlspt/   (our hosts and mods)
##       registry/mods.json  the mod registry -- see `registry.nim`
##
## Every one of `runtime/`, `client/` and `aowlspt/` is optional; a payload with
## only `aowlspt/` is how you add the mod system to an install that already has
## the rest, which is exactly what the old deploy script did.
##
## `kind` in the manifest says whether installing it mirrors a client or only
## adds to one. See `load` for why that is declared rather than inferred; the
## short version is that a post-1.0 payload has no `runtime/` and no `client/`,
## so the inference reads it as an overlay and quietly builds a target with no
## game in it.

import std/strutils
import winfs
import eft

type
  PayloadKind* = enum
    plFull      ## runtime + client: turns a vanilla install into a playable one
    plModsOnly  ## aowlspt only: assumes the rest is already there

  Payload* = object
    root*: string
    valid*: bool
    kind*: PayloadKind
    name*: string
    version*: string
    ## The client this payload's binaries were built against. This is the
    ## number the compatibility gate compares with the real install, and a
    ## payload that does not declare it is rejected rather than assumed.
    targetTarkov*: Version
    ## Which scripting backend those binaries need. A Mono BepInEx plugin
    ## cannot load into an IL2CPP client, and no version check catches that,
    ## so it is declared separately.
    targetBackend*: Backend
    ## Where the client should look for the backend server.
    backendUrl*: string
    hasRuntime*: bool
    hasClient*: bool
    hasAowlspt*: bool
    problems*: seq[string]

proc backendFromText(s: string): Backend =
  let t = toLowerAscii(strip(s))
  if t == "mono":
    result = bkMono
  elif t == "il2cpp":
    result = bkIl2Cpp
  else:
    result = bkUnknown

proc runtimeDir*(p: Payload): string = joinPath(p.root, "runtime")
proc clientDir*(p: Payload): string = joinPath(p.root, "client")
proc aowlsptDir*(p: Payload): string = joinPath(p.root, "aowlspt")

proc load*(rootIn: string): Payload =
  let root = absolutePathOf(rootIn)
  result = Payload(root: root, valid: false, kind: plModsOnly, name: "",
                   version: "", targetTarkov: parseVersion(""),
                   targetBackend: bkUnknown, backendUrl: "",
                   hasRuntime: false, hasClient: false, hasAowlspt: false,
                   problems: @[])

  if not isDirectory(root):
    result.problems.add "no such directory: " & root
    return

  let manifestPath = joinPath(root, "payload.json")
  if not fileExists(manifestPath):
    result.problems.add "no payload.json in " & root
    return

  var text = ""
  if not readTextFile(manifestPath, text):
    result.problems.add "could not read " & manifestPath
    return

  result.name = scalarAfterKey(text, "name")
  result.version = scalarAfterKey(text, "version")
  result.targetTarkov = parseVersion(scalarAfterKey(text, "targetTarkovVersion"))
  result.targetBackend = backendFromText(scalarAfterKey(text, "targetBackend"))
  result.backendUrl = scalarAfterKey(text, "backendUrl")

  result.hasRuntime = isDirectory(runtimeDir(result))
  result.hasClient = isDirectory(clientDir(result))
  result.hasAowlspt = isDirectory(aowlsptDir(result))

  # What kind of install this payload makes.
  #
  # It is declared, and only inferred when it is not. The inference -- "it
  # carries a runtime or a mod loader, so it builds a whole install" -- was
  # written for pre-1.0 Tarkov, where a playable install meant BepInEx and
  # doorstop in `client/` and SPT's server in `runtime/`. A post-1.0 payload has
  # neither: the host is injected by `aowlspt-launch` at start-up and the server
  # is one of the mods, so everything it ships lives in `aowlspt/`. Left to the
  # inference, that payload reads as an overlay -- and an overlay never mirrors
  # the client, so `install --source <vanilla> --target <new>` produces a target
  # holding `aowlspt/` and no game, reporting success. That is the whole
  # first-run path failing quietly, which is why the manifest gets to say.
  let declared = toLowerAscii(strip(scalarAfterKey(text, "kind")))
  if declared == "full":
    result.kind = plFull
  elif declared == "overlay" or declared == "modsonly" or declared == "mods":
    result.kind = plModsOnly
  elif declared.len > 0:
    result.problems.add "payload.json has \"kind\": \"" & declared &
      "\", which is neither \"full\" nor \"overlay\""
  elif result.hasRuntime or result.hasClient:
    result.kind = plFull
  else:
    result.kind = plModsOnly

  if result.name.len == 0:
    result.problems.add "payload.json has no \"name\""
  if not known(result.targetTarkov):
    result.problems.add "payload.json has no \"targetTarkovVersion\" -- " &
      "without it there is nothing to check the install against, and an " &
      "unchecked install is the failure this program exists to prevent"
  if result.targetBackend == bkUnknown:
    result.problems.add "payload.json has no \"targetBackend\" " &
      "(\"mono\" or \"il2cpp\")"
  if not (result.hasRuntime or result.hasClient or result.hasAowlspt):
    result.problems.add "payload has none of runtime/, client/, aowlspt/ -- " &
      "there is nothing to install"

  result.valid = result.problems.len == 0

proc describe*(p: Payload): seq[string] =
  result = @[]
  result.add "payload   " & p.root
  if p.name.len > 0:
    var line = "name      " & p.name
    if p.version.len > 0:
      line.add "  " & p.version
    result.add line
  result.add "built for Tarkov " & $p.targetTarkov & " (" & $p.targetBackend & ")"
  var parts: seq[string] = @[]
  if p.hasRuntime: parts.add "runtime"
  if p.hasClient: parts.add "client"
  if p.hasAowlspt: parts.add "aowlspt"
  var joined = ""
  for x in parts:
    if joined.len > 0: joined.add " + "
    joined.add x
  if joined.len == 0:
    joined = "(empty)"
  result.add "contains  " & joined
  # Spelled out rather than left to be inferred from the directory list: it
  # decides whether the client is mirrored at all, which is the difference
  # between an install you can start and a directory of libraries.
  if p.kind == plFull:
    result.add "kind      full -- the client is mirrored from --source, then " &
               "this goes over it"
  else:
    result.add "kind      overlay -- added to the install already at --target"
  if p.backendUrl.len > 0:
    result.add "backend   " & p.backendUrl
  for problem in p.problems:
    result.add "problem   " & problem
