## Identifying an Escape From Tarkov installation.
##
## Everything the installer refuses to do, it refuses on the strength of what
## this module reports, so the reporting is deliberately conservative: a fact
## is only stated when it came from the install itself, and "unknown" is a
## first-class answer rather than a guess.
##
## Three facts matter, and they are read from three independent places:
##
##   version   the `EscapeFromTarkov.exe` version resource. This is the one
##             BSG stamps at build time and the only one that cannot be made
##             to lie by copying a file in next to it.
##   backend   Mono or IL2CPP, from the shape of `EscapeFromTarkov_Data`.
##             This decides whether a managed-assembly modding stack can load
##             at all, and it is not derivable from the version number.
##   layer     whether something has already been installed over the top --
##             doorstop, BepInEx, an SPT runtime -- because patching a patched
##             install is the single most common way to end up with a client
##             that starts and then silently misbehaves.

import std/[strutils, syncio]
import std/windows/winlean
import std/widestrs
import winfs

type
  Backend* = enum
    bkUnknown   ## neither shape matched; treat as "do not touch"
    bkMono      ## EscapeFromTarkov_Data/Managed/Assembly-CSharp.dll
    bkIl2Cpp    ## GameAssembly.dll + il2cpp_data/Metadata/global-metadata.dat

  Flavour* = enum
    flVanilla   ## an untouched BSG install
    flPatched   ## doorstop and/or BepInEx present
    flSpt       ## an SPT install: SPT_Runtime beside the client
    flNotAnEft  ## no EscapeFromTarkov.exe here at all

  Version* = object
    ## Tarkov versions are dotted numbers of varying length ("1.1.0.46777",
    ## "0.16.9.40743"), so they are kept as components and compared
    ## component-wise. Storing the original text too means the installer can
    ## echo back exactly what it read.
    parts*: seq[int]
    text*: string

  EftInstall* = object
    root*: string
    exists*: bool
    flavour*: Flavour
    backend*: Backend
    version*: Version         ## from the exe version resource
    consistencyVersion*: Version  ## from ConsistencyInfo, when present
    unityVersion*: string
    buildGuid*: string
    hasBepInEx*: bool
    hasDoorstop*: bool
    hasSptRuntime*: bool
    hasBattlEye*: bool
    sptCompatibleVersion*: Version ## what an SPT_Runtime here claims to target
    notes*: seq[string]

# --------------------------------------------------------------- versions

proc parseVersion*(s: string): Version =
  ## Anything non-numeric ends the component; anything unparseable yields an
  ## empty version, which compares as "unknown" rather than as zero.
  result = Version(parts: @[], text: s)
  var cur = 0
  var have = false
  for ch in s:
    if ch >= '0' and ch <= '9':
      cur = cur * 10 + (ord(ch) - ord('0'))
      have = true
    elif ch == '.':
      if have:
        result.parts.add cur
      cur = 0
      have = false
    else:
      break
  if have:
    result.parts.add cur

proc known*(v: Version): bool =
  result = v.parts.len > 0

proc `$`*(v: Version): string =
  if v.parts.len == 0:
    result = "unknown"
  else:
    result = ""
    for i in 0 ..< v.parts.len:
      if i > 0: result.add '.'
      result.add $v.parts[i]

proc compare*(a, b: Version): int =
  ## Component-wise; a missing component counts as 0, so 1.1 == 1.1.0.
  let n = if a.parts.len > b.parts.len: a.parts.len else: b.parts.len
  for i in 0 ..< n:
    let x = if i < a.parts.len: a.parts[i] else: 0
    let y = if i < b.parts.len: b.parts[i] else: 0
    if x != y:
      return (if x < y: -1 else: 1)
  result = 0

proc isPostOneZero*(v: Version): bool =
  ## The 1.0 release is the line this installer will not cross backwards.
  ## Everything BSG shipped before it has a major of 0.
  result = v.parts.len > 0 and v.parts[0] >= 1

# --------------------------------------------------------------- exe version

type
  VS_FIXEDFILEINFO = object
    dwSignature: uint32
    dwStrucVersion: uint32
    dwFileVersionMS: uint32
    dwFileVersionLS: uint32
    dwProductVersionMS: uint32
    dwProductVersionLS: uint32
    dwFileFlagsMask: uint32
    dwFileFlags: uint32
    dwFileOS: uint32
    dwFileType: uint32
    dwFileSubtype: uint32
    dwFileDateMS: uint32
    dwFileDateLS: uint32

proc getFileVersionInfoSizeW(f: WideCString; h: var uint32): uint32 {.
  stdcall, dynlib: "version", importc: "GetFileVersionInfoSizeW", sideEffect.}
proc getFileVersionInfoW(f: WideCString; h, len: uint32; data: pointer): int32 {.
  stdcall, dynlib: "version", importc: "GetFileVersionInfoW", sideEffect.}
proc verQueryValueW(blk: pointer; sub: WideCString; buf: var pointer;
                    len: var uint32): int32 {.
  stdcall, dynlib: "version", importc: "VerQueryValueW", sideEffect.}

proc toWide(s: string): WideCStringObj =
  var t = s
  result = newWideCString(t)

proc exeVersion*(exePath: string): Version =
  ## The version resource of `EscapeFromTarkov.exe`. The buffer is a
  ## `seq[byte]` rather than a `string` on purpose: nimony strings are
  ## small-string-optimised, so they have no stable data pointer to hand to
  ## Win32.
  result = parseVersion("")
  if not fileExists(exePath):
    return
  let w = toWide(exePath)
  var handle = 0'u32
  let size = getFileVersionInfoSizeW(w.toWideCString, handle)
  if size == 0'u32:
    return
  var buf = newSeq[byte](int(size))
  if getFileVersionInfoW(w.toWideCString, 0'u32, size,
                         cast[pointer](addr buf[0])) == 0'i32:
    return
  let sub = toWide("\\")
  var out1 = cast[pointer](0)
  var len1 = 0'u32
  if verQueryValueW(cast[pointer](addr buf[0]), sub.toWideCString,
                    out1, len1) == 0'i32:
    return
  if cast[uint](out1) == 0'u:
    return
  let info = cast[ptr VS_FIXEDFILEINFO](out1)
  let ms = info.dwFileVersionMS
  let ls = info.dwFileVersionLS
  let text = $int(ms shr 16) & "." & $int(ms and 0xffff'u32) & "." &
             $int(ls shr 16) & "." & $int(ls and 0xffff'u32)
  result = parseVersion(text)

# --------------------------------------------------------------- json-ish

proc scalarAfterKey*(text, key: string): string =
  ## Pulls one scalar out of a JSON document without parsing it.
  ##
  ## This exists because the files being read are 27 MB of file manifest
  ## (`ConsistencyInfo`) and a few hundred KB of server config, and the only
  ## thing wanted from either is a single top-level string near the front.
  ## Parsing the whole document to get it would be the tail wagging the dog.
  result = ""
  let needle = "\"" & key & "\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i >= text.len:
    return
  if text[i] == '"':
    inc i
    while i < text.len and text[i] != '"':
      result.add text[i]
      inc i
  else:
    while i < text.len and text[i] != ',' and text[i] != '}' and
          text[i] != '\n' and text[i] != '\r':
      result.add text[i]
      inc i
    result = strip(result)

proc headOfFile(p: string; maxBytes: int): string =
  ## ConsistencyInfo is tens of megabytes and the version is in the first
  ## hundred bytes. Reading it all to find that would be silly.
  result = ""
  var f: File
  if not open(f, p, fmRead):
    return
  try:
    var buf = newSeq[byte](maxBytes)
    let n = readBuffer(f, cast[pointer](addr buf[0]), maxBytes)
    var i = 0
    while i < n:
      result.add char(buf[i])
      inc i
  finally:
    close(f)

# --------------------------------------------------------------- identify

proc detectBackend*(root: string): Backend =
  let dataDir = joinPath(root, "EscapeFromTarkov_Data")
  let managed = joinPath(dataDir, "Managed\\Assembly-CSharp.dll")
  let gameAssembly = joinPath(root, "GameAssembly.dll")
  let metadata = joinPath(dataDir, "il2cpp_data\\Metadata\\global-metadata.dat")

  # Mono is checked first and wins if both are present. A converted or
  # partially-patched install can be left holding a stale `il2cpp_data` tree
  # (SPT installs are, since the folder is never removed), and what decides
  # whether managed modding works is whether there are managed assemblies.
  if fileExists(managed):
    result = bkMono
  elif fileExists(gameAssembly) and fileExists(metadata):
    result = bkIl2Cpp
  else:
    result = bkUnknown

proc `$`*(b: Backend): string =
  case b
  of bkMono: result = "Mono"
  of bkIl2Cpp: result = "IL2CPP"
  of bkUnknown: result = "unknown"

proc `$`*(f: Flavour): string =
  case f
  of flVanilla: result = "vanilla"
  of flPatched: result = "patched (BepInEx/doorstop present)"
  of flSpt: result = "SPT"
  of flNotAnEft: result = "not a Tarkov install"

proc identify*(rootIn: string): EftInstall =
  let root = absolutePathOf(rootIn)
  result = EftInstall(root: root, exists: false, flavour: flNotAnEft,
                      backend: bkUnknown, version: parseVersion(""),
                      consistencyVersion: parseVersion(""),
                      unityVersion: "", buildGuid: "",
                      hasBepInEx: false, hasDoorstop: false,
                      hasSptRuntime: false, hasBattlEye: false,
                      sptCompatibleVersion: parseVersion(""), notes: @[])

  if not isDirectory(root):
    result.notes.add "no such directory"
    return

  let exe = joinPath(root, "EscapeFromTarkov.exe")
  if not fileExists(exe):
    result.notes.add "no EscapeFromTarkov.exe in this directory"
    return

  result.exists = true
  result.version = exeVersion(exe)
  result.backend = detectBackend(root)

  # ConsistencyInfo is BSG's own manifest. It is absent from an SPT install
  # (the installer removes it, since it would fail every check), so its
  # presence is itself a signal that this install is untouched.
  let consistency = joinPath(root, "ConsistencyInfo")
  if fileExists(consistency):
    let head = headOfFile(consistency, 4096)
    result.consistencyVersion = parseVersion(scalarAfterKey(head, "Version"))

  let bootCfg = joinPath(root, "EscapeFromTarkov_Data\\boot.config")
  if fileExists(bootCfg):
    var text = ""
    if readTextFile(bootCfg, text):
      for line in splitLines(text):
        let l = strip(line)
        if l.startsWith("build-guid="):
          result.buildGuid = l.substr(len("build-guid="))

  result.hasBattlEye = isDirectory(joinPath(root, "BattlEye")) or
                       fileExists(joinPath(root, "EscapeFromTarkov_BE.exe"))
  result.hasBepInEx = isDirectory(joinPath(root, "BepInEx"))
  result.hasDoorstop = fileExists(joinPath(root, "doorstop_config.ini")) or
                       fileExists(joinPath(root, "winhttp.dll"))
  result.hasSptRuntime = isDirectory(joinPath(root, "SPT_Runtime"))

  if result.hasSptRuntime:
    result.flavour = flSpt
    let core = joinPath(root, "SPT_Runtime\\SPT_Data\\configs\\core.json")
    if fileExists(core):
      let head = headOfFile(core, 4096)
      result.sptCompatibleVersion =
        parseVersion(scalarAfterKey(head, "compatibleTarkovVersion"))
  elif result.hasBepInEx or result.hasDoorstop:
    result.flavour = flPatched
  else:
    result.flavour = flVanilla

  if result.backend == bkUnknown:
    result.notes.add "neither Mono nor IL2CPP layout recognised"
  if not known(result.version):
    result.notes.add "could not read the version resource of EscapeFromTarkov.exe"

proc describe*(i: EftInstall): seq[string] =
  ## One fact per line, in the order someone reads them.
  result = @[]
  result.add "root      " & i.root
  if not i.exists:
    for n in i.notes:
      result.add "          " & n
    return
  result.add "version   " & $i.version
  if known(i.consistencyVersion):
    result.add "manifest  " & $i.consistencyVersion & "  (ConsistencyInfo)"
  result.add "backend   " & $i.backend
  result.add "flavour   " & $i.flavour
  if i.buildGuid.len > 0:
    result.add "build     " & i.buildGuid
  if known(i.sptCompatibleVersion):
    result.add "spt target " & $i.sptCompatibleVersion &
               "  (SPT_Runtime compatibleTarkovVersion)"
  var layers: seq[string] = @[]
  if i.hasDoorstop: layers.add "doorstop"
  if i.hasBepInEx: layers.add "BepInEx"
  if i.hasSptRuntime: layers.add "SPT_Runtime"
  if i.hasBattlEye: layers.add "BattlEye"
  if layers.len > 0:
    var joined = ""
    for l in layers:
      if joined.len > 0: joined.add ", "
      joined.add l
    result.add "present   " & joined
  for n in i.notes:
    result.add "note      " & n

# --------------------------------------------------------------- discovery

let
  HKEY_LOCAL_MACHINE = cast[Handle](0x80000002)
  HKEY_CURRENT_USER = cast[Handle](0x80000001)

const
  RRF_RT_REG_SZ = 0x00000002'u32
  RRF_SUBKEY_WOW6464KEY = 0x00010000'u32

proc regGetValueW(key: Handle; subKey, value: WideCString; flags: uint32;
                  kind: ptr uint32; data: pointer; dataLen: var uint32): int32 {.
  stdcall, dynlib: "advapi32", importc: "RegGetValueW", sideEffect.}

proc regString(root: Handle; subKey, value: string): string =
  result = ""
  let sk = toWide(subKey)
  let vl = toWide(value)
  var size = 0'u32
  let flags = RRF_RT_REG_SZ or RRF_SUBKEY_WOW6464KEY
  if regGetValueW(root, sk.toWideCString, vl.toWideCString, flags,
                  cast[ptr uint32](0), cast[pointer](0), size) != 0'i32:
    return
  if size == 0'u32:
    return
  var buf = newSeq[byte](int(size) + 2)
  if regGetValueW(root, sk.toWideCString, vl.toWideCString, flags,
                  cast[ptr uint32](0), cast[pointer](addr buf[0]), size) != 0'i32:
    return
  # The value comes back as UTF-16. Everything that can appear in a Windows
  # install path that this installer will accept is ASCII, and a non-ASCII
  # path is better reported as "not found" than silently mangled.
  var i = 0
  while i + 1 < int(size):
    let lo = buf[i]
    let hi = buf[i + 1]
    if lo == 0'u8 and hi == 0'u8:
      break
    if hi != 0'u8 or lo > 127'u8:
      return ""
    result.add char(lo)
    i = i + 2

proc registryCandidates*(): seq[string] =
  ## Where the BSG launcher records the install. Both hives are checked because
  ## the launcher installs per-user by default but can be installed per-machine.
  result = @[]
  const uninstallKey =
    "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\EscapeFromTarkov"
  for root in [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER]:
    let v = regString(root, uninstallKey, "InstallLocation")
    if v.len > 0:
      result.add normSep(v)

proc fixedDrives(): seq[string] =
  result = @[]
  for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ":
    let root = $letter & ":\\"
    if isDirectory(root):
      result.add $letter & ":"

const CommonSuffixes = [
  "Battlestate Games\\EFT",
  "Battlestate Games\\EFT (live)",
  "Games\\EFT",
  "Games\\Tarkov",
  "Games\\Escape From Tarkov",
  "EFT",
  "Tarkov",
  "Escape From Tarkov",
  "SPT",
  "SPTarkov",
  "Program Files\\Battlestate Games\\EFT",
  "Program Files (x86)\\Battlestate Games\\EFT"
]

proc discover*(): seq[string] =
  ## Every plausible Tarkov root on this machine, registry first. A candidate
  ## is kept only if it actually holds an `EscapeFromTarkov.exe`, so callers
  ## never have to re-check.
  var candidates: seq[string] = @[]
  # Bound to a `let` first: nimony will not let a `for` borrow from a call
  # result directly.
  let fromRegistry = registryCandidates()
  for c in fromRegistry:
    candidates.add c
  let drives = fixedDrives()
  for drive in drives:
    for suffix in CommonSuffixes:
      candidates.add joinPath(drive & "\\", suffix)

  var seen: seq[string] = @[]
  result = @[]
  for cand in candidates:
    if cand.len == 0:
      continue
    let full = absolutePathOf(cand)
    let key = toLowerAscii(full)
    var dup = false
    for s in seen:
      if s == key:
        dup = true
        break
    if dup:
      continue
    seen.add key
    if fileExists(joinPath(full, "EscapeFromTarkov.exe")):
      result.add full
