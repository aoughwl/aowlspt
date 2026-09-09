## Resolution: registry + selection -> exactly which mods load, in what order.
##
## The rules are written down in `registry/README.md` and implemented here, in
## the same order, with the same names. If the two ever disagree the README is
## the specification and this is the bug.
##
## Two properties everything below is arranged around:
##
##  * **It is a function.** Same registry, same selection, same side, same host
##    version -> same answer, every run, on every machine. Nothing consults the
##    filesystem, the clock, or the order mods happened to load in.
##  * **A failure is reported, never repaired.** A missing dependency does not
##    quietly switch something back on; a conflict is not broken by picking one.
##    Both produce an exclusion and a sentence saying who and why. A mod list
##    that silently becomes a different mod list is worse than one that refuses.
##
## Every mod in the registry comes back with a verdict, including the ones that
## were never in the running — "why is this *not* loaded" is the question people
## actually ask, and a resolver that only reports what it loaded cannot answer
## it.

import registry
import aowlspt/semver

type
  Verdict* = enum
    vLoaded          ## it will load, at position `order`
    vDisabled        ## switched off by a list or by the user
    vNotSelected     ## no active list mentions it
    vWrongSide       ## it does not declare this side
    vPipeline        ## its `pipeline` range excludes this host
    vMissingDep      ## a `requires` entry is absent, off, or the wrong version
    vConflict        ## it conflicts with another enabled mod
    vCycle           ## it is part of a `requires` cycle
    vUnknown         ## a list named it and the registry does not have it

  Decision* = object
    id*: string
    name*: string
    verdict*: Verdict
    reason*: string
    fromList*: string   ## which list (or "override") last decided its state
    explicit*: bool     ## the user said so, rather than a list
    order*: int         ## load position, or -1

  Resolution* = object
    order*: seq[string]        ## mod ids, in load order
    decisions*: seq[Decision]  ## one per registry mod, plus unknown entries
    problems*: seq[string]     ## registry-level faults: cycles, bad ranges
    pipelineChecked*: bool
    hostVersion*: string
    side*: string

proc verdictName*(v: Verdict): string =
  # An if-chain rather than a `case`: enum iteration and enum-indexed arrays do
  # not work in nimony, and one dispatch style throughout is easier to trust
  # than two.
  if v == vLoaded: return "loaded"
  if v == vDisabled: return "disabled"
  if v == vNotSelected: return "not-selected"
  if v == vWrongSide: return "wrong-side"
  if v == vPipeline: return "pipeline"
  if v == vMissingDep: return "missing-dependency"
  if v == vConflict: return "conflict"
  if v == vCycle: return "cycle"
  result = "unknown"

# ---------------------------------------------------------------------------
# Step 1-3: flatten, merge, override
# ---------------------------------------------------------------------------

type
  Merged = object
    id: string
    enabled: bool
    fromList: string
    explicit: bool

proc mergeEntry(entries: var seq[Merged]; id: string; enabled: bool;
                fromList: string; explicit: bool) =
  ## The first appearance of an id fixes its **position**; a later one updates
  ## its flag and does not move it. That is what makes an inherited override
  ## behave the way you would draw it — the child list flips a switch on the
  ## parent's entry instead of shifting the mod to the end of the load order.
  for i in 0 ..< entries.len:
    if entries[i].id == id:
      entries[i].enabled = enabled
      entries[i].fromList = fromList
      entries[i].explicit = explicit
      return
  entries.add Merged(id: id, enabled: enabled, fromList: fromList,
                     explicit: explicit)

proc contains(s: seq[string]; v: string): bool =
  for x in s:
    if x == v:
      return true
  result = false

proc dropLast(s: var seq[string]) =
  var keep: seq[string] = @[]
  for i in 0 ..< s.len - 1:
    keep.add s[i]
  s = keep

proc cyclePath(stack: seq[string]; repeated: string): string =
  ## The cycle itself, written out: `a -> b -> a`. Named rather than described,
  ## because "one of your lists inherits itself" sends a person to read four
  ## documents and "aowl.list.a -> aowl.list.b -> aowl.list.a" sends them to the
  ## line that is wrong.
  var at = -1
  for i in 0 ..< stack.len:
    if stack[i] == repeated and at < 0:
      at = i
  if at < 0:
    at = 0
  result = ""
  for i in at ..< stack.len:
    if result.len > 0: result.add " -> "
    result.add stack[i]
  if result.len > 0: result.add " -> "
  result.add repeated

proc flattenInto(reg: Registry; listId: string; stack: var seq[string];
                 seen: var seq[string]; entries: var seq[Merged];
                 problems: var seq[string]; cycled: var bool) =
  ## Depth-first over `inherits`, parents before the child's own entries.
  ##
  ## `stack` is the current path and is checked **before** `seen`: with the two
  ## the other way round, a diamond (two lists inheriting one parent) would be
  ## reported as a cycle, and a real cycle would be silently ignored.
  ##
  ## A cycle sets `cycled` and the *caller* throws the whole flattening away.
  ## Breaking the edge and carrying on -- which is what this did until the
  ## rules were read against it -- leaves a list that resolves to *something*,
  ## and what that something is depends on which of the two lists the selection
  ## happened to name first. `registry/README.md` step 1 says the list is
  ## rejected entire and named, and that is a rule worth having precisely
  ## because the alternative is a plausible-looking answer nobody can predict.
  if stack.contains(listId):
    cycled = true
    problems.add "a list inheritance cycle: " & cyclePath(stack, listId) &
                 ". Nothing in that chain is applied; fix the `inherits` of " &
                 "one of them."
    return
  if seen.contains(listId):
    return
  var idx = -1
  if not findList(reg, listId, idx):
    problems.add "no list called " & listId & " in the registry"
    return
  stack.add listId
  seen.add listId
  let inherits = reg.lists[idx].inherits
  for parent in inherits:
    flattenInto(reg, parent, stack, seen, entries, problems, cycled)
  let own = reg.lists[idx].entries
  for e in own:
    mergeEntry(entries, e.id, e.enabled, listId, false)
  dropLast(stack)

# ---------------------------------------------------------------------------
# Conflicts
# ---------------------------------------------------------------------------

proc conflictBetween(a, b: ModEntry): string =
  ## "" when there is none. Either direction counts: a mod that knows about the
  ## other should not have to wait for the other to hear about it.
  for c in a.conflicts:
    if c.id == b.id:
      return c.reason
  for c in b.conflicts:
    if c.id == a.id:
      return c.reason
  # Two mods that provide the same capability conflict without either having
  # heard of the other. That is how "two AI overhauls" is caught without every
  # AI mod having to list every other AI mod that will ever exist.
  for p in a.provides:
    for q in b.provides:
      if p == q:
        return "both provide " & p
  result = ""

# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------

proc resolve*(reg: Registry; lists: seq[string]; overrideIds: seq[string];
              overrideOn: seq[bool]; sideText, hostVersionText: string): Resolution =
  ## `overrideIds` / `overrideOn` are parallel because the caller's override
  ## record lives in `selection` and importing it here would make the resolver
  ## depend on where the selection is stored. It depends on nothing but its
  ## arguments, which is what makes it testable by inspection.
  result = Resolution(order: @[], decisions: @[], problems: @[],
                      pipelineChecked: true, hostVersion: hostVersionText,
                      side: sideText)

  # ---- 1-2: flatten and merge, in the order the selection gives.
  var merged: seq[Merged] = @[]
  for listId in lists:
    var stack: seq[string] = @[]
    var seen: seq[string] = @[]
    # Into a scratch buffer first, so that a cycle discovered half way down can
    # take the whole flattening with it rather than leaving behind the entries
    # that were merged before it was found.
    var staged: seq[Merged] = @[]
    var cycled = false
    flattenInto(reg, listId, stack, seen, staged, result.problems, cycled)
    if cycled:
      result.problems.add "the active list " & listId &
                          " contributes nothing because of that cycle"
      continue
    for m in staged:
      mergeEntry(merged, m.id, m.enabled, m.fromList, m.explicit)

  # ---- 3: the user's own decisions, last, over everything. An override for a
  # mod no active list mentions *adds* it: enabling something outside your lists
  # is an ordinary thing to want and should not require editing a list.
  for i in 0 ..< overrideIds.len:
    mergeEntry(merged, overrideIds[i], overrideOn[i], "override", true)

  # ---- Index each merged entry against the registry.
  var modIndex: seq[int] = @[]
  var alive: seq[bool] = @[]
  var verdict: seq[Verdict] = @[]
  var reason: seq[string] = @[]
  for m in merged:
    var idx = -1
    let known = findMod(reg, m.id, idx)
    modIndex.add idx
    if not known:
      # ---- 4: an entry naming a mod the registry does not have is dropped and
      # named. It stops nothing else.
      alive.add false
      verdict.add vUnknown
      reason.add "no mod with this id is in " & reg.path
      continue
    if not m.enabled:
      alive.add false
      verdict.add vDisabled
      reason.add (if m.explicit: "you turned it off"
                  else: "turned off by " & m.fromList)
      continue
    alive.add true
    verdict.add vLoaded
    reason.add "enabled by " & m.fromList

  # ---- 5: side. Information, not a fault: one binary ships to both sides and a
  # client mod in a server's list is the normal case.
  for i in 0 ..< merged.len:
    if not alive[i]:
      continue
    let m = reg.mods[modIndex[i]]
    if not hasSide(m, sideText):
      alive[i] = false
      verdict[i] = vWrongSide
      reason[i] = "declares no " & sideText & " side"

  # ---- 6: the pipeline range, against the host's own version.
  let hv = parseVersion(hostVersionText)
  if not hv.ok:
    # Refusing to load anything because the *host* misreported its version
    # would punish the wrong party. Skipped once, loudly, rather than per mod.
    result.pipelineChecked = false
    result.problems.add "the host reports its version as \"" & hostVersionText &
                        "\", which is not MAJOR.MINOR.PATCH; every `pipeline` " &
                        "range was skipped"
  else:
    for i in 0 ..< merged.len:
      if not alive[i]:
        continue
      let m = reg.mods[modIndex[i]]
      var err = ""
      let okRange = matchRange(hv, m.pipeline, err)
      if err.len > 0:
        result.problems.add m.id & ": " & err
        alive[i] = false
        verdict[i] = vPipeline
        reason[i] = err
      elif not okRange:
        alive[i] = false
        verdict[i] = vPipeline
        reason[i] = "needs aowlspt " & m.pipeline & "; this host is " &
                    hostVersionText

  # ---- 7 and 8, to a fixed point. Excluding a mod for a conflict can strand
  # something that required it, and excluding *that* can resolve nothing else --
  # so the two run together until nothing changes.
  var changed = true
  while changed:
    changed = false

    # 7: dependencies. Never auto-enabled: turning on a mod the user turned off
    # in order to satisfy something else is the manager deciding it knows
    # better. It says what is missing and lets them decide.
    for i in 0 ..< merged.len:
      if not alive[i]:
        continue
      let m = reg.mods[modIndex[i]]
      for req in m.requires:
        var depIdx = -1
        var found = false
        for k in 0 ..< merged.len:
          if merged[k].id == req.id and alive[k]:
            depIdx = modIndex[k]
            found = true
        if not found:
          alive[i] = false
          verdict[i] = vMissingDep
          reason[i] = "needs " & req.id & ", which is not loading here"
          changed = true
          break
        var err = ""
        let dv = parseVersion(reg.mods[depIdx].version)
        if not dv.ok:
          alive[i] = false
          verdict[i] = vMissingDep
          reason[i] = req.id & " declares version \"" &
                      reg.mods[depIdx].version & "\", which is not a version"
          changed = true
          break
        if not matchRange(dv, req.versionRange, err):
          alive[i] = false
          verdict[i] = vMissingDep
          reason[i] = "needs " & req.id & " " & req.versionRange &
                      "; the registry has " & reg.mods[depIdx].version &
                      (if err.len > 0: " (" & err & ")" else: "")
          changed = true
          break

    # 8: conflicts. Not auto-resolved -- both go, unless exactly one of the two
    # is there because the user explicitly said so, which is the one case where
    # somebody has actually stated a preference.
    for i in 0 ..< merged.len:
      if not alive[i]:
        continue
      for j in i + 1 ..< merged.len:
        if not alive[j]:
          continue
        let why = conflictBetween(reg.mods[modIndex[i]], reg.mods[modIndex[j]])
        if why.len == 0:
          continue
        changed = true
        if merged[i].explicit and not merged[j].explicit:
          alive[j] = false
          verdict[j] = vConflict
          reason[j] = "conflicts with " & merged[i].id & " (" & why &
                      "), which you enabled yourself"
          continue
        if merged[j].explicit and not merged[i].explicit:
          alive[i] = false
          verdict[i] = vConflict
          reason[i] = "conflicts with " & merged[j].id & " (" & why &
                      "), which you enabled yourself"
          break
        alive[i] = false
        alive[j] = false
        verdict[i] = vConflict
        verdict[j] = vConflict
        reason[i] = "conflicts with " & merged[j].id & ": " & why &
                    ". Neither is loaded; disable one."
        reason[j] = "conflicts with " & merged[i].id & ": " & why &
                    ". Neither is loaded; disable one."
        break

  # ---- 9: a stable topological sort. Merged order is the tiebreak, so the load
  # order is the list's order wherever dependencies do not force otherwise.
  var emitted: seq[bool] = @[]
  for i in 0 ..< merged.len:
    emitted.add false
  var remaining = 0
  for i in 0 ..< merged.len:
    if alive[i]:
      inc remaining

  while remaining > 0:
    var progressed = false
    for i in 0 ..< merged.len:
      if not alive[i] or emitted[i]:
        continue
      let m = reg.mods[modIndex[i]]
      var ready = true
      for req in m.requires:
        for k in 0 ..< merged.len:
          if merged[k].id == req.id and alive[k] and not emitted[k]:
            ready = false
      # `loadAfter` is soft: a name that is absent or not loading is ignored,
      # which is the whole difference between it and `requires`.
      for aft in m.loadAfter:
        for k in 0 ..< merged.len:
          if merged[k].id == aft and alive[k] and not emitted[k]:
            ready = false
      if not ready:
        continue
      emitted[i] = true
      dec remaining
      progressed = true
      result.order.add m.id
      break
    if not progressed:
      # Nothing can be emitted and things are left: every survivor is in a
      # cycle, or waiting on one. Loading them in an arbitrary order would hide
      # a registry bug that will misbehave differently on the next machine.
      var names = ""
      for i in 0 ..< merged.len:
        if alive[i] and not emitted[i]:
          alive[i] = false
          verdict[i] = vCycle
          reason[i] = "part of a `requires` or `loadAfter` cycle"
          if names.len > 0: names.add ", "
          names.add merged[i].id
      result.problems.add "a dependency cycle among " & names &
                          "; none of them is loaded"
      remaining = 0

  # ---- 10: one decision per mod in the registry, plus the unknown entries.
  for i in 0 ..< reg.mods.len:
    let m = reg.mods[i]
    var placed = false
    for k in 0 ..< merged.len:
      if merged[k].id != m.id:
        continue
      placed = true
      var pos = -1
      if verdict[k] == vLoaded:
        for o in 0 ..< result.order.len:
          if result.order[o] == m.id:
            pos = o
      result.decisions.add Decision(id: m.id, name: m.name, verdict: verdict[k],
                                    reason: reason[k],
                                    fromList: merged[k].fromList,
                                    explicit: merged[k].explicit, order: pos)
    if not placed:
      result.decisions.add Decision(id: m.id, name: m.name,
                                    verdict: vNotSelected,
                                    reason: "no active list mentions it",
                                    fromList: "", explicit: false, order: -1)

  for k in 0 ..< merged.len:
    if verdict[k] == vUnknown:
      result.decisions.add Decision(id: merged[k].id, name: merged[k].id,
                                    verdict: vUnknown, reason: reason[k],
                                    fromList: merged[k].fromList,
                                    explicit: merged[k].explicit, order: -1)

proc decisionFor*(r: Resolution; id: string; outIndex: var int): bool =
  outIndex = -1
  for i in 0 ..< r.decisions.len:
    if r.decisions[i].id == id:
      outIndex = i
      return true
  result = false

proc loadedCount*(r: Resolution): int = r.order.len
