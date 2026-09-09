## il2cppprobe -- what does a post-1.0 Tarkov client actually expose?
##
##     il2cppprobe D:\Games\Tarkov
##     il2cppprobe D:\Games\Tarkov --init
##     il2cppprobe D:\Games\Tarkov --init --class EFT.Player
##
## Without `--init` this loads `GameAssembly.dll` and reports which of the
## IL2CPP entry points aowlspt needs are present. That is a static question and
## it always answers.
##
## With `--init` it goes further and starts the runtime out of the game, which
## may or may not work: BSG ship `global-metadata.dat` encrypted, and whether
## `il2cpp_init` can decrypt it without the rest of the game's startup is an
## empirical question rather than one to reason about. If it works, every type
## in the client can be enumerated from a command line. If it does not, the
## same code paths still run inside the game, where the runtime is already up
## -- which is the case that actually matters.
##
## Nothing here writes to the install.

import std/[strutils, syncio, cmdline]
import aowlspt/il2cpp
import aowlsptinstall/[winfs, log]

const Usage = """
il2cppprobe -- inspect a post-1.0 Tarkov client's IL2CPP runtime

  il2cppprobe PATH [options]      PATH is the Tarkov install root

Options
  --init            start the runtime, not just load the module
  --class NAME      resolve one type and list its members (implies --init)
  --limit N         how many types to list per image (default 12)
  -h, --help        this
"""

type
  Options = object
    root: string
    doInit: bool
    className: string
    limit: int
    help: bool

proc parseArgs(): Options =
  result = Options(root: "", doInit: false, className: "", limit: 12,
                   help: false)
  var i = 1
  let n = paramCount()
  while i <= n:
    let a = paramStr(i)
    if a == "--init":
      result.doInit = true
    elif a == "--class":
      inc i
      if i <= n:
        result.className = paramStr(i)
        result.doInit = true
    elif a == "--limit":
      inc i
      if i <= n:
        var v = 0
        var ok = false
        for ch in paramStr(i):
          if ch >= '0' and ch <= '9':
            v = v * 10 + (ord(ch) - ord('0'))
            ok = true
          else:
            ok = false
            break
        if ok: result.limit = v
    elif a == "--help" or a == "-h":
      result.help = true
    elif a.startsWith("-"):
      fatal "unknown option: " & a
    elif result.root.len == 0:
      result.root = a
    inc i

proc main(): int =
  let o = parseArgs()
  if o.help or o.root.len == 0:
    echo Usage
    return (if o.help: 0 else: 1)

  let root = absolutePathOf(o.root)
  let gameAssembly = joinPath(root, "GameAssembly.dll")
  let dataDir = joinPath(root, "EscapeFromTarkov_Data\\il2cpp_data")
  let metadata = joinPath(dataDir, "Metadata\\global-metadata.dat")

  heading "Client"
  line "  root      " & root
  if not fileExists(gameAssembly):
    err "no GameAssembly.dll here -- this is not a post-1.0 (IL2CPP) client"
    return 1
  line "  module    " & gameAssembly & "  (" &
       $(fileSizeOf(gameAssembly) div 1048576'i64) & " MB)"
  if fileExists(metadata):
    line "  metadata  " & $(fileSizeOf(metadata) div 1048576'i64) & " MB"

  heading "Runtime"
  let rt = openIl2Cpp(gameAssembly)
  if not rt.loaded:
    err "could not load " & gameAssembly & " (error " & $rt.lastError & ")"
    return 1
  ok "GameAssembly.dll loaded"

  let gaps = missingEssential(rt)

  if rt.missing.len == 0:
    ok "every entry point aowlspt uses is exported"
  else:
    line "  " & $rt.missing.len & " of the bound entry points are absent:"
    for m in rt.missing:
      line "    " & m

  if gaps.len > 0:
    for g in gaps:
      err "essential entry point missing: " & g
    err "this client cannot be hosted through the IL2CPP C API"
    return 1
  ok "every essential entry point is present"

  if not o.doInit:
    line ""
    line "  Pass --init to start the runtime and enumerate the type universe."
    return 0

  # ------------------------------------------------------------------ init

  heading "Starting the runtime"
  line "  This is the part that may not work out of process: the metadata is"
  line "  encrypted, and the runtime decrypts it during init. Inside the game"
  line "  the runtime is already up and none of this is needed."

  if not rt.has(eSetDataDir) or not rt.has(eInit):
    err "il2cpp_set_data_dir or il2cpp_init is not exported"
    return 1

  rt.setDataDir(dataDir)
  let domain = rt.init("aowlspt-probe")
  if domain == nil:
    err "il2cpp_init returned no domain"
    line ""
    line "  That is a real answer, not a failure of this tool: the runtime"
    line "  will not come up outside the game's own startup. Type resolution"
    line "  has to happen in process, which is what the host does."
    return 2
  ok "runtime started"

  var count = 0
  let assemblies = rt.domainGetAssemblies(domain, count)
  if assemblies == nil:
    err "no assemblies"
    return 1
  ok $count & " assemblies loaded"

  heading "Images"
  var totalClasses = 0
  for i in 0 ..< count:
    let image = rt.assemblyGetImage(assemblyAt(assemblies, i))
    if image == nil:
      continue
    let n = rt.imageGetClassCount(image)
    totalClasses = totalClasses + n
    line "  " & rt.imageGetName(image) & "  " & $n & " types"
  ok $totalClasses & " types visible"

  if o.className.len == 0:
    return 0

  # ----------------------------------------------------------------- class

  heading o.className
  let c = findClass(rt, o.className)
  if c == nil:
    err "not found"
    return 1
  ok "resolved: " & fullName(rt, c)

  let parent = rt.classParent(c)
  if parent != nil:
    line "  extends   " & fullName(rt, parent)
  line "  size      " & $rt.classInstanceSize(c) & " bytes"

  line ""
  line "  methods"
  var iter: Il2CppIter = nullPtr()
  var shown = 0
  while shown < o.limit:
    let m = rt.nextMethod(c, iter)
    if m == nil:
      break
    line "    " & rt.methodName(m) & "/" & $rt.methodParamCount(m)
    inc shown

  line ""
  line "  fields"
  var fiter: Il2CppIter = nullPtr()
  shown = 0
  while shown < o.limit:
    let f = rt.nextField(c, fiter)
    if f == nil:
      break
    line "    +" & $rt.fieldOffset(f) & "  " & rt.fieldName(f)
    inc shown

  result = 0

quit(main())
