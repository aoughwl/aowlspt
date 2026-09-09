## The record of what was installed, so uninstall can be exact.
##
## Written as plain text, one path per line, rather than JSON. An uninstall
## manifest is the file someone reads when they no longer trust the program
## that wrote it -- and at that moment "open it and look" beating "parse it"
## is worth more than structure. It is also the file a `findstr` can answer
## questions about.

import std/strutils
import winfs

const
  JournalName* = "aowlspt-install.txt"
  Header = "# aowlspt installer manifest"

type
  Journal* = object
    path*: string
    source*: string
    payload*: string
    tarkovVersion*: string
    ## What `payload.json` called itself: the aowlspt release this install was
    ## made from. Recorded because nothing else in a finished install says --
    ## the binaries carry no version resource and the payload directory it came
    ## from may be long gone -- and "which build is this" is the first question
    ## asked about an install that misbehaves.
    payloadVersion*: string
    installedAt*: string
    ## "full" when the target directory is entirely this installer's -- it
    ## holds a client that was mirrored from the source. "overlay" when the
    ## payload was added on top of an install somebody else made. Uninstall
    ## says something different in each case, and it is the difference between
    ## removing a game and removing a mod.
    mode*: string
    ## Top-level paths under the target that the installer created. Uninstall
    ## removes these and nothing else.
    paths*: seq[string]

proc journalPath*(target: string): string =
  result = joinPath(target, JournalName)

proc newJournal*(target, source, payload, tarkovVersion, payloadVersion, stamp,
                 mode: string): Journal =
  result = Journal(path: journalPath(target), source: source, payload: payload,
                   tarkovVersion: tarkovVersion,
                   payloadVersion: payloadVersion, installedAt: stamp,
                   mode: mode, paths: @[])

proc render*(j: Journal): string =
  result = Header & "\n"
  result.add "# Removing the paths listed below undoes this installation.\n"
  result.add "#\n"
  result.add "source " & j.source & "\n"
  result.add "payload " & j.payload & "\n"
  result.add "tarkov " & j.tarkovVersion & "\n"
  if j.payloadVersion.len > 0:
    result.add "aowlspt " & j.payloadVersion & "\n"
  result.add "mode " & j.mode & "\n"
  if j.installedAt.len > 0:
    result.add "installed " & j.installedAt & "\n"
  result.add "\n"
  for p in j.paths:
    result.add "path " & p & "\n"

proc save*(j: Journal): FsResult =
  result = writeTextFile(j.path, render(j))

proc load*(target: string): Journal =
  result = Journal(path: journalPath(target), source: "", payload: "",
                   tarkovVersion: "", payloadVersion: "", installedAt: "",
                   mode: "", paths: @[])
  var text = ""
  if not readTextFile(result.path, text):
    return
  for line in splitLines(text):
    let l = strip(line)
    if l.len == 0 or l.startsWith("#"):
      continue
    let cut = find(l, " ")
    if cut < 0:
      continue
    let key = l.substr(0, cut - 1)
    let value = strip(l.substr(cut + 1))
    if key == "source":
      result.source = value
    elif key == "payload":
      result.payload = value
    elif key == "tarkov":
      result.tarkovVersion = value
    elif key == "aowlspt":
      result.payloadVersion = value
    elif key == "installed":
      result.installedAt = value
    elif key == "mode":
      result.mode = value
    elif key == "path":
      result.paths.add value

proc hasJournal*(target: string): bool =
  result = fileExists(journalPath(target))
