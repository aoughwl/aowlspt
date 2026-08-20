## What the installer is about to do, as data.
##
## Nothing here touches the disk until `apply` is called, and `apply` does
## exactly what `render` printed -- same list, same order. That is the point:
## a dry run is not a separate code path that approximates the real one, it is
## the real one with the last step withheld. An installer whose preview can
## disagree with its behaviour is not worth previewing.
##
## Applying also writes a journal (see `journal.nim`) naming every path
## created, so uninstall removes what was installed rather than what it guesses
## was installed.

import std/strutils
import winfs
import log

type
  StepKind* = enum
    skMkDir       ## create a directory
    skCopyTree    ## copy a directory recursively
    skMirrorTree  ## hard link a directory recursively, copying what cannot link
    skCopyFile
    skWriteFile   ## write `content` to `dst`
    skRemoveTree

  Step* = object
    kind*: StepKind
    src*: string
    dst*: string
    content*: string
    why*: string
    ## Names under `src` that a tree step must not reproduce. Matched
    ## case-insensitively against the first path component and against the
    ## whole relative path, which between them cover everything worth
    ## excluding from a game install.
    skip*: seq[string]
    ## Names that must be *copied* even when the step is otherwise mirroring
    ## by hard link. Same matching as `skip`. See `applyTree`.
    hot*: seq[string]

  Plan* = object
    target*: string
    steps*: seq[Step]
    ## True when the target directory is wholly this installer's creation --
    ## i.e. the plan lays down a client as well as a payload. It changes what
    ## uninstall means, so it is recorded rather than re-derived: for a whole
    ## target, uninstall removes the target; for an overlay onto somebody
    ## else's install, it removes only the entries that were added.
    wholeTarget*: bool

  ApplyStats* = object
    filesLinked*: int
    filesCopied*: int
    filesWritten*: int
    dirsCreated*: int
    bytesCopied*: int64
    failures*: int
    ## Every path created at the top level of the target, for the journal.
    created*: seq[string]

proc newPlan*(target: string; wholeTarget: bool): Plan =
  result = Plan(target: absolutePathOf(target), steps: @[],
                wholeTarget: wholeTarget)

proc mkdir*(p: var Plan; dst, why: string) =
  p.steps.add Step(kind: skMkDir, src: "", dst: dst, content: "", why: why,
                   skip: @[], hot: @[])

proc copyTree*(p: var Plan; src, dst, why: string) =
  p.steps.add Step(kind: skCopyTree, src: src, dst: dst, content: "", why: why,
                   skip: @[], hot: @[])

proc mirrorTree*(p: var Plan; src, dst, why: string; skip: seq[string] = @[];
                 hot: seq[string] = @[]) =
  p.steps.add Step(kind: skMirrorTree, src: src, dst: dst, content: "",
                   why: why, skip: skip, hot: hot)

proc copyFile*(p: var Plan; src, dst, why: string) =
  p.steps.add Step(kind: skCopyFile, src: src, dst: dst, content: "", why: why,
                   skip: @[], hot: @[])

proc writeFile*(p: var Plan; dst, content, why: string) =
  p.steps.add Step(kind: skWriteFile, src: "", dst: dst, content: content,
                   why: why, skip: @[])

proc removeTree*(p: var Plan; dst, why: string) =
  p.steps.add Step(kind: skRemoveTree, src: "", dst: dst, content: "", why: why,
                   skip: @[], hot: @[])

# --------------------------------------------------------------- rendering

proc describe*(s: Step): string =
  case s.kind
  of skMkDir: result = "mkdir   " & s.dst
  of skCopyTree: result = "copy    " & s.src & "  ->  " & s.dst
  of skMirrorTree:
    result = "mirror  " & s.src & "  ->  " & s.dst
    if s.skip.len > 0:
      var joined = ""
      for x in s.skip:
        if joined.len > 0: joined.add ", "
        joined.add x
      result.add "  (without " & joined & ")"
  of skCopyFile: result = "copy    " & s.src & "  ->  " & s.dst
  of skWriteFile: result = "write   " & s.dst
  of skRemoveTree: result = "remove  " & s.dst

proc render*(p: Plan): seq[string] =
  result = @[]
  for s in p.steps:
    result.add describe(s)
    if s.why.len > 0:
      result.add "        " & s.why

# --------------------------------------------------------------- applying

proc humanBytes*(n: int64): string =
  if n < 1024'i64:
    result = $n & " B"
  elif n < 1024'i64 * 1024'i64:
    result = $(n div 1024'i64) & " KB"
  elif n < 1024'i64 * 1024'i64 * 1024'i64:
    result = $(n div (1024'i64 * 1024'i64)) & " MB"
  else:
    let gb = n div (1024'i64 * 1024'i64 * 1024'i64)
    let frac = (n mod (1024'i64 * 1024'i64 * 1024'i64)) div
               (102'i64 * 1024'i64 * 1024'i64)
    result = $gb & "." & $frac & " GB"

proc firstComponent(rel: string): string =
  let cut = find(rel, "\\")
  if cut < 0:
    result = rel
  else:
    result = rel.substr(0, cut - 1)

proc matches(rel: string; names: seq[string]): bool =
  ## True when `rel` is one of `names`, or lives under one of them. Compared
  ## case-insensitively, and with separators normalised, because these lists
  ## are written by hand in source and on Windows nobody agrees on either.
  if names.len == 0:
    return false
  let full = toLowerAscii(normSep(rel))
  let head = toLowerAscii(firstComponent(normSep(rel)))
  for n in names:
    let want = toLowerAscii(normSep(n))
    if want == head or want == full:
      return true
    if full.len > want.len and full.substr(0, want.len - 1) == want and
       full[want.len] == '\\':
      return true
  result = false

proc recordCreated(stats: var ApplyStats; target, p: string)

proc applyTree(src, dst: string; mirror: bool; skip, hot: seq[string];
               target: string; perEntry: bool; stats: var ApplyStats) =
  ## Recreates `src` under `dst`.
  ##
  ## When `mirror` is on and the two sides share a volume, every file becomes a
  ## hard link: the target install occupies no additional space and appears in
  ## seconds rather than in the time it takes to move 40 GB. The catch, and the
  ## reason this is not simply always on, is that a hard link is the same file
  ## -- writing through one writes through the other. Nothing here ever writes
  ## into a mirrored file: the steps that produce modified content are
  ## `skWriteFile` and `skCopyFile`, and both replace the destination rather
  ## than opening it, which breaks the link first.
  var files: seq[string] = @[]
  var dirs: seq[string] = @[]
  collectEntries(src, files, dirs)

  let canLink = mirror and sameVolume(src, dst)
  if mirror and not canLink:
    note "  source and target are on different volumes; copying instead"

  let mk = ensureDir(dst)
  if not mk.ok:
    err "cannot create " & dst & " (error " & $mk.err & ")"
    inc stats.failures
    return
  inc stats.dirsCreated

  for rel in dirs:
    if matches(rel, skip):
      continue
    let r = ensureDir(joinPath(dst, rel))
    if r.ok:
      inc stats.dirsCreated
      if perEntry:
        recordCreated(stats, target, joinPath(dst, rel))
    else:
      err "mkdir " & rel & ": error " & $r.err
      inc stats.failures

  var linkFellBack = false
  for rel in files:
    if matches(rel, skip):
      detail "skip " & rel
      continue
    let from1 = joinPath(src, rel)
    let to1 = joinPath(dst, rel)
    var done = false

    # A hard link is not a copy: it is a second name for the same bytes, so
    # anything that later opens the target file for writing -- a patcher, a mod
    # manager, a text editor, the game itself -- writes into the source install
    # too. The installer is careful about this in its own writes (see
    # `winfs.copyFileAt`), but it cannot be careful on behalf of every tool
    # that will touch the install afterwards.
    #
    # So the files that something might plausibly rewrite are copied even when
    # everything else is linked. On a Tarkov install that is a few hundred
    # megabytes of executables and managed assemblies against ~78 GB of asset
    # bundles, which buys back nearly all of the speed and none of the risk.
    let mustCopy = matches(rel, hot)
    if mustCopy:
      detail "copy (not linked) " & rel

    if canLink and not linkFellBack and not mustCopy:
      let r = hardLinkAt(from1, to1)
      if r.ok:
        inc stats.filesLinked
        done = true
      else:
        # One failure is enough to conclude linking is not available here --
        # trying it on every one of forty thousand files, and paying a failed
        # syscall each time, is slower than just copying.
        linkFellBack = true
        note "  hard links unavailable (error " & $r.err & "); copying instead"

    if not done:
      let r = copyFileAt(from1, to1)
      if r.ok:
        inc stats.filesCopied
        let sz = fileSizeOf(to1)
        if sz > 0'i64:
          stats.bytesCopied = stats.bytesCopied + sz
      else:
        err "copy " & rel & ": error " & $r.err
        inc stats.failures

    if perEntry:
      recordCreated(stats, target, to1)
    detail rel

proc topLevelOf(target, p: string): string =
  ## The first component of `p` below `target`, which is the granularity the
  ## journal records at: uninstall removes `<target>\BepInEx`, not forty
  ## thousand individual files.
  if not isUnder(p, target):
    return absolutePathOf(p)
  let full = absolutePathOf(p)
  let base = absolutePathOf(target)
  if full.len <= base.len + 1:
    return full
  let rest = full.substr(base.len + 1)
  let cut = find(rest, "\\")
  if cut < 0:
    result = joinPath(base, rest)
  else:
    result = joinPath(base, rest.substr(0, cut - 1))

proc recordCreated(stats: var ApplyStats; target, p: string) =
  let top = topLevelOf(target, p)
  for c in stats.created:
    if c == top:
      return
  stats.created.add top

proc apply*(p: Plan; mirror: bool): ApplyStats =
  ## `perEntry` recording is off for a whole-target install: there the answer
  ## is just the target, and listing its forty top-level directories would make
  ## the manifest look like it had a choice about them.
  let perEntry = not p.wholeTarget
  result = ApplyStats(filesLinked: 0, filesCopied: 0, filesWritten: 0,
                      dirsCreated: 0, bytesCopied: 0'i64, failures: 0,
                      created: @[])

  for s in p.steps:
    say describe(s)
    if dryRun():
      continue

    case s.kind
    of skMkDir:
      let r = ensureDir(s.dst)
      if r.ok:
        inc result.dirsCreated
        if perEntry:
          recordCreated(result, p.target, s.dst)
      else:
        err "mkdir " & s.dst & ": error " & $r.err
        inc result.failures

    of skCopyTree:
      applyTree(s.src, s.dst, false, s.skip, s.hot, p.target, perEntry, result)

    of skMirrorTree:
      applyTree(s.src, s.dst, mirror, s.skip, s.hot, p.target, perEntry, result)

    of skCopyFile:
      let r = copyFileAt(s.src, s.dst)
      if r.ok:
        inc result.filesCopied
        if perEntry:
          recordCreated(result, p.target, s.dst)
      else:
        err "copy " & s.dst & ": error " & $r.err
        inc result.failures

    of skWriteFile:
      let r = writeTextFile(s.dst, s.content)
      if r.ok:
        inc result.filesWritten
        if perEntry:
          recordCreated(result, p.target, s.dst)
      else:
        err "write " & s.dst & ": error " & $r.err
        inc result.failures

    of skRemoveTree:
      let r = winfs.removeTree(s.dst)
      if not r.ok:
        err "remove " & s.dst & ": error " & $r.err
        inc result.failures

  if p.wholeTarget:
    result.created = @[p.target]

proc summarise*(s: ApplyStats): seq[string] =
  result = @[]
  var line = ""
  if s.filesLinked > 0:
    line.add $s.filesLinked & " linked"
  if s.filesCopied > 0:
    if line.len > 0: line.add ", "
    line.add $s.filesCopied & " copied (" & humanBytes(s.bytesCopied) & ")"
  if s.filesWritten > 0:
    if line.len > 0: line.add ", "
    line.add $s.filesWritten & " written"
  if line.len == 0:
    line = "nothing to do"
  result.add line
  result.add $s.dirsCreated & " directories"
  if s.failures > 0:
    result.add $s.failures & " failures"
