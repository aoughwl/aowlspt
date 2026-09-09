## Whether the resolved load order may be written down.
##
## `aowlspt-selection.json`, beside the mods, decides what the *next* start
## loads. `host/common/modhost.nim` honours it to the letter when it names at
## least one mod, and refuses an empty `load` array — at length, and for exactly
## the argument this module is the other half of:
##
##     it is the document a manager writes when it could not read its own
##     store, it is indistinguishable from one written for a player who chose
##     nothing, and only one of those two readings can brick an install.
##
## The host cannot make that refusal stick, because the document that bricks an
## install is not the empty one. It is the one naming **this manager and nothing
## else** — same shape as a legitimate ten-mod document, and the host has no way
## to know which of the ids in a `load` array is the manager. That id is known
## here, so the refusal belongs here.
##
## ## What actually went wrong
##
## A UTF-8 byte-order mark on the manager's `config.json`. The host's per-key
## lookup could not find `activeLists` in a document that did not parse and
## answered "no such key"; `readConfig` read that as the empty string, which is
## also what `"activeLists": []` reads as; nothing was seeded; nothing resolved;
## and the manager wrote down that the correct thing to load was itself. The
## next boot loaded one mod out of ten and said nothing, because every layer
## involved was doing what it was told.
##
## The BOM is stripped in two places now. That is not the fix. **The fix is that
## the manager can no longer act on the difference between "you selected
## nothing" and "I could not read what you selected", because it can now tell
## them apart and refuses when it cannot.**
##
## ## The rule
##
## A document that names something other than the manager is always fine —
## whatever else is wrong, the player still has mods and still has a manager to
## change them with.
##
## A document that names *only* the manager is written **only when every input
## that could have produced it was intact**: the config parsed, the store was
## readable, the registry loaded and describes mods, every active list exists,
## the resolution had no problems in it, and the host reported a version the
## `pipeline` ranges could be checked against. Then it is an answer to a
## question somebody asked — a player who switched everything off is entitled to
## exactly that file — and it is written.
##
## Otherwise the previous file is left exactly as it is. That is the state a
## person can still boot out of: the old order, or no file at all and a host
## that walks the directory and loads everything.
##
## ## Why it takes its facts as an argument
##
## Because the version that read globals could not be tested, and an untestable
## refusal is a refusal nobody knows fires. Every field below is something the
## caller already has; nothing here reads a file, a clock or a global. Drive it
## with a `WriteFacts` and it answers, which is what makes "prove this check can
## fail" a four-line thing to do rather than a staged install.

type
  WriteFacts* = object
    ## Everything the decision turns on, and nothing else.
    protectedId*: string
      ## The mod that may not be switched off — `aowl.manager`. An `order`
      ## containing nothing but this is the degenerate document.
    order*: seq[string]
      ## The resolved load order, *as resolved* — not the document, which has
      ## the protected id put back into it.
    configFault*: string
      ## "" when `config.json` parsed. The sentence saying why not, otherwise.
    configNamedLists*: bool
      ## Whether `activeLists` in a config that parsed named at least one id.
    selectionFault*: string
      ## "" when the stored selection was read. The sentence, otherwise.
    selectionSeeded*: bool
      ## Whether the active lists came from the config's defaults rather than
      ## from the store — i.e. nothing has ever been saved.
    registryOk*: bool
    registryError*: string
    registryPath*: string
    registryMods*: int
    activeLists*: seq[string]
    knownLists*: seq[string]
      ## Every list id the registry has, including the player's own local ones.
      ## Compared against `activeLists` rather than assumed to contain it.
    problems*: seq[string]
      ## The resolution's own problems: cycles, unknown lists, bad ranges.
    pipelineChecked*: bool
    hostVersion*: string

proc noFacts*(): WriteFacts =
  ## A `WriteFacts` with nothing in it. Written out in full rather than left to
  ## default initialisation, because a global in an `--app:lib` build that needs
  ## a call to initialise is left zeroed, and because a fixture assembled by
  ## mutation is a fixture whose last statement can be forgotten.
  result = WriteFacts(protectedId: "", order: @[], configFault: "",
                      configNamedLists: false, selectionFault: "",
                      selectionSeeded: false, registryOk: false,
                      registryError: "", registryPath: "", registryMods: 0,
                      activeLists: @[], knownLists: @[], problems: @[],
                      pipelineChecked: true, hostVersion: "")

proc protectedOnly*(f: WriteFacts): bool =
  ## Whether the document would name the protected mod and nothing else —
  ## including the case where the resolution is empty, because the protected id
  ## is put back in and the two produce the same bytes on disk.
  for id in f.order:
    if id != f.protectedId:
      return false
  result = true

proc unknownActiveList*(f: WriteFacts): string =
  ## The first active list the registry does not have, or "".
  for want in f.activeLists:
    var found = false
    for have in f.knownLists:
      if have == want:
        found = true
    if not found:
      return want
  result = ""

proc selectionWriteFault*(f: WriteFacts): string =
  ## "" when the document may be written beside the mods, and the sentence to
  ## print when it may not.
  if not protectedOnly(f):
    return ""

  if f.configFault.len > 0:
    return "the resolution came out empty and " & f.configFault &
           ". A config that cannot be read produces the same empty answer as " &
           "a config that selects nothing, and only one of those is something " &
           "you asked for"
  if f.selectionFault.len > 0:
    return "the resolution came out empty and " & f.selectionFault
  if not f.registryOk:
    return "the resolution came out empty because there is no registry to " &
           "resolve against: " & f.registryError
  if f.registryMods == 0:
    return "the resolution came out empty because " & f.registryPath &
           " describes no mods at all; a registry with nothing in it selects " &
           "nothing, which is not the same as you selecting nothing"
  let missing = unknownActiveList(f)
  if missing.len > 0:
    return "the resolution came out empty and the active list " & missing &
           " is not in " & f.registryPath &
           ", so nothing could have been selected by it"
  if f.problems.len > 0:
    return "the resolution came out empty and it had a problem in it: " &
           f.problems[0]
  if not f.pipelineChecked:
    return "the resolution came out empty and every `pipeline` range was " &
           "skipped because the host reports its version as \"" &
           f.hostVersion & "\", so no mod was ever really considered"
  if f.activeLists.len == 0 and f.configNamedLists and f.selectionSeeded:
    # Belt and braces for the original bug, stated as its own sentence: the
    # config named lists, nothing has ever been stored, and the active set came
    # out empty anyway. That has no innocent reading — it means the seeding did
    # not happen — and it is the one check that would have fired on the BOM even
    # if `readConfig` had gone on reading one key at a time.
    return "the resolution came out empty, nothing has ever been stored, and " &
           "config.json names lists that did not reach the selection. The " &
           "manager does not know what you chose, so it will not write down " &
           "that you chose nothing"
  result = ""
