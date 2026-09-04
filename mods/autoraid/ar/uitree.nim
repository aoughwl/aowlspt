## ar/uitree.nim -- WALKING THE LIVE UI TREE, BOUNDED AND BREADTH-FIRST.
##
## Every walker here is a port of the host's `autoraid.nim`, and every one of
## them is breadth-before-depth for the SAME MEASURED REASON. This is the single
## most expensive lesson in that file and it is repeated here in full, because a
## depth-first rewrite of any of these would look correct, would pass review,
## and would silently find nothing:
##
##   The controls in this game's menus are SHALLOW and the character models are
##   DEEP. `MatchMaker Side Selection Screen -> PMCs` has, at level 1,
##   `[PMCPlayerMV] [AnimatedToggleSpawner] [Button] [ScavPlayerMV]
##   [RandomToggleSpawner]`. `PMCPlayerMV` is the character MODEL: a mesh with
##   thousands of nodes. A depth-first walk with a 40-node cap spends the whole
##   cap inside that mesh and never reaches its sibling two nodes to the right.
##   MEASURED 2026-09-02: the depth-first version reported ZERO pressable nodes
##   under that screen; the level-by-level one finds them in the first two
##   levels. The same defect made a DFS collect find 0 `MenuScreen`s live while
##   a breadth-first walk had found one at 42 seconds.
##
## There are two DIFFERENT breadth-first shapes here and the difference is not
## cosmetic. `walkActive` / `collect` are BREADTH-PER-NODE: they take a whole
## level, then recurse into the first child -- which is depth-first one level
## down, and under a screen with a character model in it that is fatal in
## exactly the way above. `collectBFS` is a TRUE level-by-level BFS using its
## own queue: EVERY node of level N is visited before ANY node of level N+1, so
## a control at level 2 is always found before a mesh node at level 3. Anything
## that has to look INSIDE a screen with a model in it uses `collectBFS`.
##
## BOUNDS
## ------
## Every walk is bounded three ways at once, and all three are load-bearing:
## a NODE BUDGET (so a cyclic or enormous tree cannot spin), a WALL-CLOCK SLICE
## checked INSIDE the walk (so one frame cannot be eaten), and a FANOUT cap per
## level (a wide root has many children). Exceeding the slice POISONS the budget
## to zero, which unwinds every recursion level at once rather than letting the
## next level start a fresh descent.
##
## The slice is generous -- 120 ms -- and that is deliberate rather than sloppy:
## these walks run AT THE MENU ONLY. The machine reaches DONE the instant READY
## is pressed and never touches the UI again during a raid load (fact #261), so
## a brief main-thread hang at the menu is acceptable and it makes discovery
## near-instant instead of fragile.
##
## NOTHING HERE PRESSES ANYTHING. Discovery and action are separate files on
## purpose: a walker that could also act would make it possible to press a node
## found under a relaxed predicate.

import aowlspt
import aowlspt/il2cpp
import native
import calls

const
  WalkMs* = 120'i64
    ## Per-walk wall-clock slice, checked INSIDE the walk. Menu-only; see above.
  NodeBudget* = 120000
    ## Per-walk node cap. Large so a walk of a known screen completes in ONE
    ## tick even with thousands of nodes, rather than starving mid-walk and
    ## reporting an absence that is really a truncation.
  Fanout* = 512
    ## Children examined per level.
  FindDepth* = 16
    ## Descent depth for a by-name search under a screen.
  MapDepth* = 8
    ## Depth from a location tile's toggle down to its `Label` TMP.
  ScreenDepth* = 6
    ## Descent from a screen receiver to its own `ScreenDefaultButtons ->
    ## NextButton`, which is at depth 2 (measured live). Six leaves room without
    ## inviting a walk into a character model.
  CensusCap* = 24
    ## Names printed by a refusal census. A refusal that names nothing is a
    ## shrug; a refusal that names everything is a wall of text nobody reads.
  MaxNamesLen* = 620
    ## Characters of collected names carried into one log line.

proc trim*(s: string): string =
  ## Strip leading/trailing ASCII whitespace. Map labels are padded on this
  ## build, so an untrimmed compare simply never matches and looks like a
  ## missing map.
  var a = 0
  var b = s.len - 1
  while a <= b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n'):
    inc a
  while b >= a and (s[b] == ' ' or s[b] == '\t' or s[b] == '\r' or s[b] == '\n'):
    dec b
  result = ""
  var i = a
  while i <= b:
    result.add s[i]
    inc i

proc lower*(s: string): string =
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c >= 'A' and c <= 'Z':
      result.add char(int(c) + 32)
    else:
      result.add c
    inc i

proc contains*(hay, needle: string): bool =
  ## Plain substring test. Local rather than imported so that this file has no
  ## dependency outside the mod folder beyond the SDK itself.
  if needle.len == 0: return true
  if needle.len > hay.len: return false
  var i = 0
  while i <= hay.len - needle.len:
    var j = 0
    while j < needle.len and hay[i + j] == needle[j]:
      inc j
    if j == needle.len: return true
    inc i
  result = false

proc deadlineNow*(): int64 =
  ## The wall-clock end of one walk's slice.
  nowMs() + WalkMs

# ---------------------------------------------------------------------------
# Breadth-per-node: a by-name search and a collect. Cheap, and correct for a
# subtree with no character model in it.
# ---------------------------------------------------------------------------

proc walkActive*(t: Il2CppPtr; name: string; depth: int; budget: var int;
                 deadline: int64; exclude: Il2CppPtr): Il2CppPtr =
  ## The first ACTIVE node named `name` under `t`, excluding one pointer.
  ##
  ## ACTIVE is required, not preferred: an inactive control is NOT PRESSABLE
  ## (fact #72), and pressing one returns success and does nothing -- which is
  ## the worst possible outcome, because the machine then advances believing it
  ## acted. A node that matches by name but reads inactive is deliberately NOT
  ## returned and the search continues past it.
  ##
  ## `exclude` is how a screen-to-screen transition is deduplicated: the button
  ## just pressed must not be re-found and re-pressed as if it were the next
  ## screen's.
  result = nil
  if t == nil or depth < 0 or budget <= 0 or not readable(t, 0x20): return
  budget = budget - 1
  if (budget and 31) == 0 and nowMs() > deadline:
    budget = 0                          # poison: unwinds every level at once
    return
  if t != exclude and nodeName(t) == name and isActive(t):
    return t
  if depth == 0: return
  var ok = false
  let n = childCount(t, ok)
  if not ok: return
  # Pass 1 -- BREADTH: name+active check every direct child, no descent.
  var i = 0
  while i < n and i < Fanout and budget > 0:
    let c = childAt(t, i, n)
    if c != nil:
      budget = budget - 1
      if (budget and 31) == 0 and nowMs() > deadline:
        budget = 0
        return
      if c != exclude and nodeName(c) == name and isActive(c):
        return c
    i = i + 1
  # Pass 2 -- DEPTH: recurse only after the whole level has missed.
  i = 0
  while i < n and i < Fanout and budget > 0:
    let c = childAt(t, i, n)
    if c != nil:
      result = walkActive(c, name, depth - 1, budget, deadline, exclude)
      if result != nil: return
    i = i + 1

proc collectChildren(t: Il2CppPtr; name: string; depth: int; budget: var int;
                     deadline: int64; into: var seq[Il2CppPtr]; cap: int) =
  ## The body of `collect`. It does NOT check `t` itself -- the caller already
  ## did -- so each node is name-checked EXACTLY once, as some parent's direct
  ## child or as the collect root, and there are no duplicate hits.
  if depth <= 0 or budget <= 0 or into.len >= cap: return
  var ok = false
  let n = childCount(t, ok)
  if not ok: return
  var i = 0
  while i < n and i < Fanout and budget > 0 and into.len < cap:
    let c = childAt(t, i, n)
    if c != nil:
      budget = budget - 1
      if (budget and 31) == 0 and nowMs() > deadline:
        budget = 0
        return
      if nodeName(c) == name:
        into.add c
        if into.len >= cap: return
    i = i + 1
  i = 0
  while i < n and i < Fanout and budget > 0 and into.len < cap:
    let c = childAt(t, i, n)
    if c != nil:
      collectChildren(c, name, depth - 1, budget, deadline, into, cap)
    i = i + 1

proc collect*(t: Il2CppPtr; name: string; depth: int; budget: var int;
              deadline: int64; into: var seq[Il2CppPtr]; cap: int) =
  ## Up to `cap` nodes named `name` under `t`, ACTIVE OR NOT.
  ##
  ## Active-or-not is required by at least one caller and is not an oversight:
  ## the daily-reward popup rebuilds `MenuScreen`/`PlayButton`, so the FIRST
  ## MenuScreen by name can be the DEAD instance whose PlayButton is inactive
  ## while a live one exists under a second. Collecting all of them and then
  ## asking each for an ACTIVE, PRESSABLE PlayButton finds the live one without
  ## a parent-climb, which rejected valid buttons live.
  if t == nil or budget <= 0 or into.len >= cap or not readable(t, 0x20): return
  budget = budget - 1
  if (budget and 31) == 0 and nowMs() > deadline:
    budget = 0
    return
  if nodeName(t) == name:
    into.add t
    if into.len >= cap: return
  collectChildren(t, name, depth, budget, deadline, into, cap)

# ---------------------------------------------------------------------------
# TRUE level-by-level BFS. The one to use under any screen that might contain a
# character model -- which is every matchmaker screen.
# ---------------------------------------------------------------------------

proc collectBFS*(root: Il2CppPtr; depth: int; budget: var int; deadline: int64;
                 into: var seq[Il2CppPtr]; cap: int; skip: string) =
  ## Every ACTIVE node under `root`, level by level, using `q` as the queue.
  ##
  ## `skip` excludes a whole SUBTREE by a lowercased name substring, and it is
  ## how one side of the side selector is chosen without guessing: BOTH sides
  ## live under `PMCs`, and the scav one is nested inside a `ScavPlayerMV`
  ## subtree, so "the PMC control" is structurally "the first control under
  ## `PMCs` that is NOT under a scav node". There is no name and no caption that
  ## expresses that; the tree shape does.
  if root == nil or depth <= 0 or budget <= 0 or cap <= 0: return
  let start = into.len
  var q: seq[Il2CppPtr] = @[]
  q.add root
  var head = 0
  var levelEnd = 1
  var lvl = 0
  while head < q.len and lvl < depth and into.len - start < cap and budget > 0:
    let node = q[head]
    head = head + 1
    var ok = false
    let n = childCount(node, ok)
    if ok:
      var j = 0
      while j < n and j < Fanout and into.len - start < cap and budget > 0:
        let c = childAt(node, j, n)
        if c != nil:
          budget = budget - 1
          if (budget and 31) == 0 and nowMs() > deadline:
            budget = 0
            return
          if isActive(c) and
             (skip.len == 0 or not contains(lower(nodeName(c)), skip)):
            into.add c
            q.add c
        j = j + 1
    if head >= levelEnd:
      levelEnd = q.len
      lvl = lvl + 1

proc findActiveNamedBFS*(root: Il2CppPtr; name: string; depth, cap: int;
                         visited: var int; names: var string): Il2CppPtr =
  ## The ACTIVE node named `name` under `root`, found LEVEL BY LEVEL, AND a
  ## report of how many nodes were examined and what they were called.
  ##
  ## The census is not decoration. MEASURED 2026-09-02: the breadth-per-node
  ## walker returned nil EIGHT TIMES IN A ROW for a `NextButton` that the
  ## inspector proved was at depth 2 under the very same receiver -- because it
  ## recursed into child 0, which on that screen is `PMCs`, and poisoned its own
  ## budget inside the character mesh before reaching the sibling
  ## `ScreenDefaultButtons`. Without the names, that failure is
  ## indistinguishable from the button not existing.
  ##
  ## So a refusal built on this reports THREE distinguishable states: the wanted
  ## name IS in the list (the comparison is wrong), the count is AT THE CAP (the
  ## search was truncated), or the count is tiny (the receiver is not the
  ## screen).
  result = nil
  visited = 0
  names = ""
  if root == nil or name.len == 0: return
  var nodes: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collectBFS(root, depth, b, deadlineNow(), nodes, cap, "")
  visited = nodes.len
  var i = 0
  while i < nodes.len:
    let nm = nodeName(nodes[i])
    if nm.len > 0 and names.len < MaxNamesLen:
      names = names & "[" & nm & "]"
    if result == nil and nm == name:
      result = nodes[i]
    i = i + 1

proc collectActiveBF*(t: Il2CppPtr; depth: int; budget: var int;
                      deadline: int64; into: var seq[Il2CppPtr]; cap: int;
                      skip: string) =
  ## Every ACTIVE node under `t`, breadth-before-depth, skipping a named
  ## subtree. The breadth-per-node shape, used where the subtree is known to be
  ## shallow (a settings screen, a census at depth <= 2).
  if t == nil or depth <= 0 or budget <= 0 or into.len >= cap: return
  var ok = false
  let n = childCount(t, ok)
  if not ok: return
  var i = 0
  while i < n and i < Fanout and budget > 0 and into.len < cap:
    let c = childAt(t, i, n)
    if c != nil:
      budget = budget - 1
      if (budget and 31) == 0 and nowMs() > deadline:
        budget = 0
        return
      if isActive(c) and
         (skip.len == 0 or not contains(lower(nodeName(c)), skip)):
        into.add c
        if into.len >= cap: return
    i = i + 1
  i = 0
  while i < n and i < Fanout and budget > 0 and into.len < cap:
    let c = childAt(t, i, n)
    if c != nil and isActive(c) and
       (skip.len == 0 or not contains(lower(nodeName(c)), skip)):
      collectActiveBF(c, depth - 1, budget, deadline, into, cap, skip)
    i = i + 1

# ---------------------------------------------------------------------------
# Text
# ---------------------------------------------------------------------------

proc tmpTextOf*(node: Il2CppPtr): string =
  ## The `TMPro.TextMeshProUGUI` text on a node, or "" for NO TMP or an
  ## unreadable one. `m_text` @0xE0, read RAW and guarded -- this mod never
  ## writes it, so the `LocalizedText` clobber trap has no surface here.
  result = ""
  var why = ""
  let comp = componentOf(node, TypeRvaTmpUgui, why)
  if comp == nil: return
  if not readable(comp, OffTmpText + 8): return
  let sp = readPtr(comp, OffTmpText)
  if sp == nil: return
  result = readString(sp)

proc labelUnderName*(node: Il2CppPtr; name: string; depth: int): string =
  ## The TMP text of the first ACTIVE descendant named `name`.
  ##
  ## "" is NOT FOUND **or** NOT READABLE and must never be treated as a match:
  ## an empty string compares equal to nothing useful, which is exactly how a
  ## check that cannot fail gets written. Every caller tests `.len > 0` first.
  result = ""
  var hits: seq[Il2CppPtr] = @[]
  var b = NodeBudget
  collectBFS(node, depth, b, deadlineNow(), hits, 24, "")
  var i = 0
  while i < hits.len:
    if nodeName(hits[i]) == name:
      let t = trim(tmpTextOf(hits[i]))
      if t.len > 0: return t
    i = i + 1

proc census*(root: Il2CppPtr; depth: int; count: var int; into: var string) =
  ## The names of the ACTIVE nodes at depth <= `depth` under `root`.
  ##
  ## THE HONEST ANSWER TO "WHAT IS ON SCREEN". It guesses no class names and
  ## asserts nothing: it reports what the live tree really has ACTIVE. A step
  ## that times out saying "the control never became visible" has named only
  ## what we failed to find; a census names what the client actually had up,
  ## which is what settles where the flow really is.
  if root == nil or depth <= 0 or count >= CensusCap: return
  var ok = false
  let n = childCount(root, ok)
  if not ok: return
  var i = 0
  while i < n and i < Fanout and count < CensusCap:
    let c = childAt(root, i, n)
    if c != nil and isActive(c):
      count = count + 1
      if into.len < 700:
        into = into & "[" & nodeName(c) & "]"
      census(c, depth - 1, count, into)
    i = i + 1

proc censusUnder*(root: Il2CppPtr; depth: int): string =
  ## One line naming what is ACTIVE under a receiver, for a refusal.
  if root == nil:
    return " (no receiver to look under)"
  var count = 0
  var names = ""
  census(root, depth, count, names)
  result = " ACTIVE under the receiver (depth<=" & $depth & ", " & $count &
           "): " & (if names.len > 0: names else: "<none>")
