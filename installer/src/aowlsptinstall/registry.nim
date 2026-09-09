## The mod registry, and the selection a fresh install starts life with.
##
## Two things a person expects after installing: a list of what exists, and a
## sensible set of it switched on. Neither is a binary, so neither arrives with
## the hosts -- and without them `mods/manager` comes up reporting "no registry
## found. Looked at: ..." and manages nothing, on an install that is otherwise
## complete. That failure is invisible until the game is running, which is the
## worst time to discover it.
##
## **The registry.** `registry/mods.json` in this repository: every mod that
## exists, and every named list of them. `mods/manager` searches for it at
## `<modsRoot>/registry/mods.json` and at `<modsRoot>/../registry/mods.json`,
## among others, so this module puts it at `<target>/aowlspt/registry/mods.json`
## -- which is the second of those, and is inside the one directory the
## installer owns and can therefore remove again.
##
## **The selection.** The manager seeds its stored selection, on first run only,
## from `activeLists` in its own `config.json`. There is no other seeding path:
## no file it reads at startup, no flag. So "install a default selection" means
## exactly one thing that works -- set that key in the config that gets
## installed.
##
## It is set by *patching the payload's copy*, not by writing a config of this
## module's invention. A config written here would be missing every key the mod
## grows after today, and the mod would silently fall back to defaults for all
## of them. Patching replaces one value and leaves the rest of the document,
## comments included, exactly as the mod author wrote it -- and when the key is
## not found in the shape expected, this module changes nothing and says so,
## rather than appending a key that might be the second one in the file.

import std/strutils
import winfs

const
  ## Where the manager looks. `mods/manager/manager.nim` builds this candidate
  ## as `parentOf(modsRoot()) & "/registry/mods.json"`; keep the two together.
  RegistryRelPath* = "aowlspt\\registry\\mods.json"
  ## The manager's config, relative to the target, once the payload is down.
  ManagerConfigRelPath* = "aowlspt\\mods\\manager\\config.json"
  ## Core plus the three client mods that change how the game feels without
  ## changing what is in it. Chosen over `aowl.list.core` because core alone is
  ## the emulator and nothing else -- a correct install, and one where the mod
  ## manager has a single row in it and nothing to demonstrate.
  DefaultList* = "aowl.list.vanillaplus"
  ## `--list none` -- install the registry, leave the payload's own default
  ## alone. Spelled out so that "no default selection" is something a person
  ## asked for rather than something that happened.
  NoList* = "none"

proc registryIn*(payloadRoot: string): string =
  ## The registry inside a payload, or "" when it carries none.
  ##
  ## Two locations, most preferred first. `aowlspt/registry/mods.json` is where
  ## `aowl payload` should stage it, and lands in the target through the
  ## ordinary `aowlspt/` copy; `registry/mods.json` beside `payload.json` is the
  ## top-level form, for a payload assembled by hand or by something that is not
  ## this repository's build tool. Either is installed to the same place.
  result = ""
  if payloadRoot.len == 0:
    return
  let inner = joinPath(payloadRoot, "aowlspt\\registry\\mods.json")
  if fileExists(inner):
    return inner
  let outer = joinPath(payloadRoot, "registry\\mods.json")
  if fileExists(outer):
    return outer

proc resolveRegistry*(payloadRoot, explicit: string): string =
  ## `--registry` wins, and may name either the file or the directory holding
  ## it, because both are things a person types. An explicit path that does not
  ## exist returns "" rather than falling back to the payload's: silently
  ## installing a different registry than the one asked for is how somebody
  ## ends up debugging a mod list they are not running.
  if explicit.len > 0:
    let p = absolutePathOf(explicit)
    if fileExists(p):
      return p
    let inDir = joinPath(p, "mods.json")
    if fileExists(inDir):
      return inDir
    return ""
  result = registryIn(payloadRoot)

proc schemaOf*(text: string): string =
  ## The registry's `schema` string, for reporting. Read with the same
  ## one-scalar-out-of-a-big-document trick `eft.scalarAfterKey` uses; a full
  ## parse to print one line would be the tail wagging the dog, and the
  ## manager parses the file properly anyway.
  result = ""
  let needle = "\"schema\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or text[i] == '\t'):
    inc i
  if i >= text.len or text[i] != '"':
    return
  inc i
  while i < text.len and text[i] != '"':
    result.add text[i]
    inc i

proc countOccurrences(text, needle: string): int =
  result = 0
  if needle.len == 0:
    return
  var i = 0
  while i + needle.len <= text.len:
    if text.substr(i, i + needle.len - 1) == needle:
      inc result
      i = i + needle.len
    else:
      inc i

proc describeRegistry*(text: string): seq[string] =
  ## What is in a registry, without parsing it: how many mods, how many lists.
  ##
  ## Counted off `"artifact"` and `"entries"` -- one of each per mod and per
  ## list, and required by the schema -- rather than off `"id"`, which every
  ## dependency, conflict and list entry also carries. Counting ids reported
  ## nine mods and fifteen lists for a registry holding eight and four, which is
  ## the kind of number that is worse than no number: it is checked by nobody
  ## and believed by everybody.
  result = @[]
  let schema = schemaOf(text)
  if schema.len > 0:
    result.add "schema    " & schema
  result.add "contains  " & $countOccurrences(text, "\"artifact\"") &
             " mods, " & $countOccurrences(text, "\"entries\"") & " lists"

proc hasList*(text, listId: string): bool =
  ## Whether the registry actually defines the list an install is about to be
  ## defaulted to. A default naming a list that is not there resolves to
  ## nothing, and the player sees an install with every mod off and no reason
  ## given -- so it is checked here, where there is still something to say.
  result = find(text, "\"" & listId & "\"") >= 0

# --------------------------------------------------------- the default list

proc patchActiveLists*(text, listId: string): string =
  ## `text` with its `"activeLists"` value replaced by `[ "<listId>" ]`, or ""
  ## when the key is not there in the shape expected.
  ##
  ## Returning "" rather than a best effort is deliberate. The alternatives --
  ## appending the key, or rewriting the file from a template held here -- both
  ## produce a config that looks right and is not: a duplicate key resolves to
  ## whichever copy the parser reaches last, and a template drops every setting
  ## added since this file was written.
  ##
  ## The key `"//activeLists"` -- the mod's own documentation for the setting --
  ## sits immediately above the real one in the shipped config. It does not
  ## match, because the needle starts with the opening quote and there is no
  ## quote directly before `a` in `"//activeLists"`. The value shape is checked
  ## too: only a `[` after the colon is the array being replaced.
  result = ""
  let needle = "\"activeLists\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or
                          text[i] == '\t' or text[i] == '\r' or
                          text[i] == '\n'):
    inc i
  if i >= text.len or text[i] != '[':
    return
  var close = i
  while close < text.len and text[close] != ']':
    inc close
  if close >= text.len:
    return
  var replacement = "[]"
  if listId.len > 0:
    replacement = "[\"" & listId & "\"]"
  result = text.substr(0, i - 1) & replacement & text.substr(close + 1)

proc activeListsOf*(text: string): string =
  ## The `activeLists` value as written, for reporting what an install is
  ## being left with when nothing is patched.
  result = ""
  let needle = "\"activeLists\""
  let at = find(text, needle)
  if at < 0:
    return
  var i = at + needle.len
  while i < text.len and (text[i] == ' ' or text[i] == ':' or
                          text[i] == '\t' or text[i] == '\r' or
                          text[i] == '\n'):
    inc i
  if i >= text.len or text[i] != '[':
    return
  var close = i
  while close < text.len and text[close] != ']':
    inc close
  if close >= text.len:
    return
  result = strip(text.substr(i, close))
