## The `aowl ui` and `aowl raid` command surface.
##
## Kept apart from `aowlui.nim` so the navigation layer stays usable as a
## library (a future `aowl test` gate, a harness) without dragging a command
## parser along with it.

import std/[strutils, syncio]
import aowlsptinstall/winfs
import aowlui

const UiUsage* = """
aowl ui -- drive the live client's UI by the text a PERSON sees

  roots                       every scene root
  screens                     every screen under --root, with its active state
  screen                      just the ACTIVE screen names (plural on purpose)
  dump [NAME]                 the labelled controls of a screen (default: the
                              active one) -- "what can I press here"
  findtext TEXT               every control whose DISPLAYED text matches
  click TEXT                  find by displayed text, resolve the pressable
                              component, actuate it
  children PTR                direct children of a transform
  tree PTR [DEPTH]            the host's own tree walk (truncates at 128 lines)
  ancestors PTR               the parent chain
  button PTR                  the pressable component at or above PTR
  labels PTR                  the displayed text of PTR's children
  inraid                      yes / no / UNKNOWN -- unknown is a real answer
  regcount                    RegisterPlayer events seen (NOT an in-raid test)
  wait-screen NAME            block until that screen is active
  wait-noroot NAME            block until that scene root is gone
  cache list|put KEY PATH|resolve KEY|clear
  selftest                    the offline checks: parsers, path maths, the
                              completeness flag. Touches no client.

Flags (every text verb takes --root; hardcoding one root is what stopped the
Python version reaching anything under `Menu UI`)
  --root NAME       scene root to search      (default: Common UI)
  --exact           case-insensitive equality rather than substring
  --all             walk INACTIVE nodes too (default: only what is on screen)
  --budget N        node ceiling for a walk   (default: 4000)
  --up N            ancestors to consider for `button`/`click` (default: 5)
  --expect-screen S after a click, wait for screen S under --root
  --expect-noroot S after a click, wait for scene root S to disappear
  --settle S        seconds to wait for that effect              (default: 20)
  --timeout S       seconds per inspector batch                  (default: 45)
  --live PATH       the live install  (default: D:\Aowlspt\aowlspt)

Exit codes: 0 answered, 2 the channel or the walk failed, 4 the action failed.
"""

const RaidUsage* = """
aowl raid -- enter an offline raid, by pressing what a player presses

  --map NAME          the location to select   (default: factory)
  --insurance         take the insurance step rather than skipping it
                      (REFUSED: the item-selection procedure is not known)
  --practice          tick "Enable practice mode for this raid"
                      (NOT YET AUTOMATABLE -- see the note it prints)
  --dry-run           print the steps and press nothing
  --settle S          seconds to allow each screen transition    (default: 25)
  --load-timeout S    seconds to wait for the raid to load       (default: 600)
  --live PATH         the live install

This encodes the `enter-offline-raid` recipe. Every step is a click BY
DISPLAYED TEXT and every step but the toggle waits for the screen it is
supposed to produce, so a step that "worked" without advancing is reported as
the failure it is. The mode selector / profile select is a PRECONDITION: run
`python tools\entergame.py` first if the main menu is not up.
"""

type
  Opts* = object
    live*, root*, expectScreen*, expectNoRoot*: string
    exact*, all*, dryRun*, practice*, insurance*, timeoutPinned*: bool
    budget*, up*, settleMs*, timeoutMs*, loadMs*: int
    map*: string
    words*: seq[string]     ## positional arguments, in order

proc defaultOpts*(): Opts =
  result = Opts(live: "", root: "Common UI", expectScreen: "",
                expectNoRoot: "", exact: false, all: false, dryRun: false,
                practice: false, insurance: false, timeoutPinned: false,
                budget: 4000, up: 5,
                settleMs: 20000, timeoutMs: 45000, loadMs: 600000,
                map: "factory", words: @[])

proc parseOpts*(args: seq[string]; o: var Opts; bad: var string): bool =
  ## Anything that is not a known flag is a positional word. A text argument
  ## may be several words (`click ESCAPE FROM TARKOV`), so they are joined by
  ## the caller rather than limited to one.
  bad = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--root" or a == "--live" or a == "--map" or
       a == "--expect-screen" or a == "--expect-noroot":
      inc i
      if i >= args.len:
        bad = a & " needs a value"
        return false
      if a == "--root": o.root = args[i]
      elif a == "--live": o.live = args[i]
      elif a == "--map": o.map = args[i]
      elif a == "--expect-screen": o.expectScreen = args[i]
      else: o.expectNoRoot = args[i]
    elif a == "--budget" or a == "--up" or a == "--settle" or
         a == "--timeout" or a == "--load-timeout":
      inc i
      if i >= args.len:
        bad = a & " needs a value"
        return false
      let v = parseNat(args[i])
      if v < 0:
        bad = a & " wants a non-negative number, not '" & args[i] & "'"
        return false
      if a == "--budget": o.budget = v
      elif a == "--up": o.up = v
      elif a == "--settle": o.settleMs = v * 1000
      elif a == "--timeout":
        o.timeoutMs = v * 1000
        o.timeoutPinned = true
      else: o.loadMs = v * 1000
    elif a == "--exact": o.exact = true
    elif a == "--all": o.all = true
    elif a == "--dry-run": o.dryRun = true
    elif a == "--practice": o.practice = true
    elif a == "--insurance": o.insurance = true
    elif a == "--no-insurance": o.insurance = false
    elif a.startsWith("--"):
      bad = "unknown option: " & a
      return false
    else:
      o.words.add a
    inc i
  result = true

proc restText(o: Opts; fromIdx: int): string =
  var parts: seq[string] = @[]
  var i = fromIdx
  while i < o.words.len:
    parts.add o.words[i]
    inc i
  result = joinStr(parts, " ")

proc expectOf(o: Opts): Expect =
  if o.expectNoRoot.len > 0:
    result = Expect(kind: xkNoRoot, name: o.expectNoRoot, root: o.root)
  elif o.expectScreen.len > 0:
    result = Expect(kind: xkScreen, name: o.expectScreen, root: o.root)
  else:
    result = noExpect()

proc pad(s: string; n: int): string =
  result = s
  while result.len < n: result.add ' '

proc clip(s: string; n: int): string =
  if s.len <= n: result = s
  else: result = s.substr(0, n - 1)

# ---------------------------------------------------------------------------
# `aowl ui selftest` -- everything that can be checked WITHOUT the client.
#
# Which is: the parsers, the pointer map, the number reader and the
# completeness flag. That is not most of the risk in this tool -- the risk is
# in the live channel -- but it IS the part that has silently produced wrong
# answers before (a tree regex that required "(N child)" dropped every leaf,
# and a positional hex grab handed back a klass pointer), so it is the part
# worth pinning down. Every fixture below is a real line shape from the host.
# ---------------------------------------------------------------------------

var stChecks = 0
var stBad = 0

proc check(what: string; cond: bool) =
  inc stChecks
  if not cond:
    inc stBad
    echo "  FAIL  " & what

proc checkEq(what, got, want: string) =
  check(what & " (got '" & got & "', wanted '" & want & "')", got == want)

proc selfTest*(): int =
  # ---- THE CHANNEL LOCK'S IDENTITY, against known answers ----
  #
  # The lock is only worth anything if it names the SAME FILE `channel.py`
  # names. That is a pure function of a string, so it is checkable here with no
  # client and no filesystem -- and it is exactly the part that can silently
  # drift into a lock nobody else can see, which READS AS PROTECTION and is
  # not. "a9993e364706" is SHA-1("abc") truncated, the standard known answer;
  # "ad4ef68aa8f3" is hashlib.sha1(os.path.abspath(LIVE).lower().encode())
  # .hexdigest()[:12] as computed by the Python on this machine, whose
  # os.path.abspath returns forward slashes -- which is exactly why both
  # spellings are locked (see normLive).
  checkEq("sha1 hex is lowercase and truncated to 12", sha1Hex12("abc"),
          "a9993e364706")
  checkEq("live path normalises (backslash spelling)",
          normLive("D:\\Aowlspt\\aowlspt\\", '\\'), "d:\\aowlspt\\aowlspt")
  checkEq("live path normalises (forward spelling)",
          normLive("D:\\Aowlspt\\aowlspt", '/'), "d:/aowlspt/aowlspt")
  checkEq("lock name matches channel.py, forward spelling",
          sha1Hex12(normLive("D:\\Aowlspt\\aowlspt", '/')), "ad4ef68aa8f3")
  check("the two lock spellings really are different files",
        lockPathFor("D:\\Aowlspt\\aowlspt", '\\') !=
        lockPathFor("D:\\Aowlspt\\aowlspt", '/'))

  # A `roots` line.
  let rootLine = "  [$r3] transform=0x1f2a3b4c50 go=0x1f2a3b4c60 ($rgo3) " &
                 "name=\"Menu UI\""
  var rs: seq[Node] = @[]
  check("roots parses one line", parseRoots(rootLine, rs))
  check("roots found exactly one", rs.len == 1)
  if rs.len == 1:
    checkEq("roots transform", rs[0].t, "0x1f2a3b4c50")
    checkEq("roots gameobject", rs[0].go, "0x1f2a3b4c60")
    checkEq("roots name", rs[0].name, "Menu UI")

  # A `parent` line: transform=, klass=, name=, go= all on ONE line. Reading
  # "the second hex number" here hands back the KLASS, and GetComponent on a
  # klass pointer FAULTS.
  let parentLine = "  [1] transform=0xAAA0 klass=0xBBB0 name=\"PlayButton\" " &
                   "go=0xCCC0 activeSelf=true"
  checkEq("parent transform is not the klass", hexAfter(parentLine,
          "transform="), "0xAAA0")
  checkEq("parent gameobject is not the klass", hexAfter(parentLine, "go="),
          "0xCCC0")
  checkEq("parent activeSelf", wordAfter(parentLine, "activeSelf="), "true")

  # `children`.
  let childLine = "  [0] transform=0x1110 ($c0)  go=0x2220 ($g0)  " &
                  "name=\"SizeLabel\""
  var kids: seq[Node] = @[]
  parseChildren(childLine, @["Menu UI"], kids)
  check("children parsed", kids.len == 1)
  if kids.len == 1:
    checkEq("children name", kids[0].name, "SizeLabel")
    checkEq("children path", joinStr(kids[0].path, "/"), "Menu UI/SizeLabel")

  # `tree`. The LEAF has no "(N child)" suffix, and a parser that requires one
  # drops every label in the subtree while still looking like it worked.
  let treeOut = "\"MenuScreen\" 0x1000 (2 child)\n" &
                "  \"PlayButton\" 0x1100 (1 child)\n" &
                "    \"Label\" 0x1110\n" &
                "  \"QuitButton\" 0x1200\n" &
                "42 node(s) printed -- complete."
  var tn: seq[Node] = @[]
  check("tree parsed", parseTree(treeOut, tn))
  check("tree kept the LEAF nodes", tn.len == 4)
  if tn.len == 4:
    checkEq("tree leaf path", joinStr(tn[2].path, "/"),
            "MenuScreen/PlayButton/Label")
    checkEq("tree sibling path", joinStr(tn[3].path, "/"),
            "MenuScreen/QuitButton")

  # A name may legitimately be empty; "absent" and "empty" are different.
  var nm = "x"
  check("empty name is PRESENT, not absent",
        quotedAfter("name=\"\" go=0x10", "name=", nm))
  checkEq("empty name is empty", nm, "")
  check("a missing field is absent",
        not quotedAfter("go=0x10", "name=", nm))

  # Numbers out of host output: "not a number" is ordinary, not exceptional.
  check("parseNat reads a number", parseNat("22") == 22)
  check("parseNat refuses a non-number", parseNat("2a") == -1)
  check("parseNat refuses empty", parseNat("") == -1)

  # The pointer map.
  var m = initPtrMap(64)
  mput(m, "0xdead", 7)
  mput(m, "0xbeef", 9)
  check("map reads back", mget(m, "0xdead") == 7)
  check("map reads back the second", mget(m, "0xbeef") == 9)
  check("map says -1 for absent", mget(m, "0xfeed") == -1)
  mput(m, "0xdead", 8)
  check("map overwrites", mget(m, "0xdead") == 8)

  # The completeness flag is the whole safety story.
  checkEq("complete reads as complete", completenessNote(true), "COMPLETE")
  check("incomplete SAYS absence proves nothing",
        completenessNote(false).contains("absence proves nothing"))

  # Three-state, never two.
  checkEq("unknown is its own answer", triText(triUnknown), "unknown")

  echo "  " & $(stChecks - stBad) & "/" & $stChecks & " offline checks passed."
  if stBad > 0:
    echo "  NOTE: this covers the PARSERS only. Nothing here exercises the " &
         "live channel, the batch caps, the retry or any actuation."
    return 2
  echo "  NOTE: this covers the PARSERS only. Nothing here exercises the " &
       "live channel, the batch caps, the retry or any actuation -- those " &
       "are UNVERIFIED until run against a client."
  result = 0

# ---------------------------------------------------------------------------

proc cmdUi*(repo: string; args: seq[string]): int =
  if args.len == 0 or args[0] == "help" or args[0] == "--help" or
     args[0] == "-h":
    echo UiUsage
    return (if args.len == 0: 1 else: 0)
  var o = defaultOpts()
  var bad = ""
  var rest: seq[string] = @[]
  var i = 1
  while i < args.len:
    rest.add args[i]
    inc i
  if not parseOpts(rest, o, bad):
    echo "!! " & bad
    return 1
  var u = initUi(o.live, o.timeoutMs, o.timeoutPinned)
  let verb = args[0]
  let visibleOnly = not o.all

  case verb
  of "roots":
    var rs: seq[Node] = @[]
    if not roots(u, rs):
      echo "!! " & u.lastErr
      return 2
    for r in rs:
      echo "  " & pad(r.name, 34) & " t=" & r.t & " go=" & r.go
  of "screens", "screen":
    var ss = default(ScreenSet)
    if not screens(u, o.root, ss):
      echo "!! " & u.lastErr
      return 2
    if not ss.rootPresent:
      # PORT FIX (bug 1): not an error. `Menu UI` being gone is the most
      # reliable in-raid signal there is.
      echo "there is no scene root named '" & o.root & "'."
      echo "  " & u.lastErr
      if o.root == "Menu UI":
        echo "  On this build that means the menu is UNLOADED, which is " &
             "positive evidence a raid is in progress."
      return 0
    if verb == "screen":
      let act = activeScreens(ss)
      if act.len == 0:
        echo "active: <none under " & o.root & ">"
      else:
        echo "active: " & joinStr(act, ", ")
    else:
      for s in ss.screens:
        var mark = "  ?  "
        if s.active == triYes: mark = "ACTIVE"
        elif s.active == triNo: mark = "      "
        echo "  " & pad(s.name, 38) & " " & mark & "  " & s.t
  of "dump":
    var rows: seq[Hit] = @[]
    var complete = false
    if not dumpScreen(u, restText(o, 0), o.root, visibleOnly, rows, complete):
      echo "!! " & u.lastErr
      return 2
    for r in rows:
      echo "  " & pad("'" & clip(r.text, 40) & "'", 44) & tailPath(r.path, 3)
    echo "  -- " & $rows.len & " labelled node(s); tree walk " &
         completenessNote(complete)
  of "findtext":
    var hits: seq[Hit] = @[]
    var complete = false
    if not findText(u, restText(o, 0), o.root, o.exact, o.budget, visibleOnly,
                    "", hits, complete):
      echo "!! " & u.lastErr
      return 2
    for h in hits:
      echo "  " & h.t & "  " & pad("'" & clip(h.text, 28) & "'", 32) &
           tailPath(h.path, 4)
    echo "  -- " & $hits.len & " hit(s); tree walk " &
         completenessNote(complete)
  of "click":
    let r = clickText(u, restText(o, 0), o.root, o.exact, "", expectOf(o),
                      o.settleMs, visibleOnly)
    if r.ok: echo "OK: " & r.msg
    else: echo "FAILED: " & r.msg
    return (if r.ok: 0 else: 4)
  of "children":
    if o.words.len == 0:
      echo "!! children needs a pointer"
      return 1
    var kids: seq[Node] = @[]
    if not children(u, o.words[0], kids):
      echo "!! " & u.lastErr
      return 2
    for k in kids:
      echo "  " & pad(k.name, 34) & " t=" & k.t & " go=" & k.go
  of "tree":
    if o.words.len == 0:
      echo "!! tree needs a pointer"
      return 1
    var depth = 4
    if o.words.len > 1:
      let d = parseNat(o.words[1])
      if d < 0:
        echo "!! tree DEPTH wants a number, not '" & o.words[1] & "'"
        return 1
      depth = d
    var w = default(Walk)
    if not tree(u, o.words[0], depth, w):
      echo "!! " & u.lastErr
      return 2
    for n in w.nodes:
      echo "  " & pad("", n.depth * 2) & n.name & "  " & n.t
    echo "  -- " & $w.nodes.len & " node(s); host walk " &
         completenessNote(w.complete)
  of "ancestors":
    if o.words.len == 0:
      echo "!! ancestors needs a pointer"
      return 1
    var chain: seq[Anc] = @[]
    if not ancestors(u, o.words[0], o.up, chain):
      echo "!! " & u.lastErr
      return 2
    for a in chain:
      var act = "inactive"
      if a.activeSelf: act = "active"
      echo "  " & pad(a.name, 34) & " t=" & a.t & " " & act
  of "button":
    if o.words.len == 0:
      echo "!! button needs a pointer"
      return 1
    var b = default(Button)
    if not buttonFor(u, o.words[0], o.up, b):
      echo "!! " & u.lastErr
      return 2
    if b.found:
      echo "  " & b.kind & " on " & b.name & " at " & b.at
      echo "  chain: " & joinStr(b.chain, " <- ")
    else:
      var kinds: seq[string] = @[]
      for k in 0 ..< ButtonComponents.len: kinds.add ButtonComponents[k]
      echo "  nothing pressable on " & o.words[0] & " or its " & $o.up &
           " nearest ancestors (tried " & joinStr(kinds, ", ") & ")."
      return 4
  of "labels":
    if o.words.len == 0:
      echo "!! labels needs a pointer"
      return 1
    var kids: seq[Node] = @[]
    if not children(u, o.words[0], kids):
      echo "!! " & u.lastErr
      return 2
    var ptrs: seq[string] = @[]
    for k in kids: ptrs.add k.t
    var texts: seq[string] = @[]
    if not labelsOf(u, ptrs, texts):
      echo "!! " & u.lastErr
      return 2
    for j in 0 ..< kids.len:
      var t = texts[j]
      if t.len == 0: t = "<no text component here>"
      else: t = "'" & t & "'"
      echo "  " & pad(kids[j].name, 34) & t
  of "inraid":
    let v = inRaid(u, "Menu UI")
    case v
    of triYes:
      echo "IN RAID"
    of triNo:
      echo "NOT in a raid (the menu root is loaded and active)"
    of triUnknown:
      echo "UNKNOWN -- neither `Game Scene` nor the menu root gave a " &
           "positive answer. Saying unknown rather than guessing."
      echo "  " & u.lastErr
      return 2
  of "regcount":
    let rc = registerPlayerCount(u)
    if rc.known:
      echo "RegisterPlayer events this host session: " & $rc.count
      echo "  NOT an in-raid test: measured, it fires when the SERVER " &
           "starts (5 events at server start, 22 once the player was " &
           "actually in), and it never decreases when a raid ends."
    else:
      echo "UNKNOWN -- " & rc.why
      return 2
  of "wait-screen", "wait-noroot":
    let name = restText(o, 0)
    if name.len == 0:
      echo "!! " & verb & " needs a name"
      return 1
    var e = Expect(kind: xkScreen, name: name, root: o.root)
    if verb == "wait-noroot": e = Expect(kind: xkNoRoot, name: name, root: o.root)
    if waitUntil(u, e, o.settleMs):
      echo "OK: " & name & " reached the expected state."
    else:
      echo "FAILED: " & name & " did not reach the expected state within " &
           $(o.settleMs div 1000) & "s. That is a measured timeout, not proof " &
           "the state is unreachable."
      return 4
  of "cache":
    if o.words.len == 0:
      echo "!! cache needs list|put|resolve|clear"
      return 1
    let sub = o.words[0]
    if sub == "list":
      let c = loadCache(u, repo)
      if c.wasStale:
        echo "  (the cache was written against a different game build and " &
             "was discarded WHOLE.)"
      echo "  scope " & c.scope
      for e in c.entries:
        echo "  " & pad(e.key, 28) & joinStr(e.path, "/")
    elif sub == "put":
      if o.words.len < 3:
        echo "!! cache put needs KEY and a Root/Name/Name path"
        return 1
      if cachePut(u, repo, o.words[1], o.words[2].split('/')):
        echo "OK: recorded " & o.words[1]
      else:
        echo "!! could not write " & cachePath(repo)
        return 2
    elif sub == "resolve":
      if o.words.len < 2:
        echo "!! cache resolve needs a KEY"
        return 1
      var hit = default(Node)
      var how = ""
      if cachedPath(u, repo, o.words[1], hit, how):
        echo "OK (" & how & "): t=" & hit.t & " go=" & hit.go
      else:
        echo "FAILED (" & how & "): the cached path does not resolve; " &
             "re-derive it and `cache put` the new one."
        return 4
    elif sub == "clear":
      var empty = Cache(scope: scopeKey(u), entries: @[], wasStale: false)
      discard saveCache(u, repo, empty)
      echo "OK: cache cleared."
    else:
      echo "!! unknown cache sub-command: " & sub
      return 1
  of "selftest":
    return selfTest()
  else:
    echo "!! unknown `aowl ui` verb: " & verb
    echo UiUsage
    return 1
  result = 0

# ---------------------------------------------------------------------------
# aowl raid
# ---------------------------------------------------------------------------

type
  Step = object
    text*: string        ## the DISPLAYED text to press
    root*: string        ## which scene root it lives under
    wantScreen*: string  ## the screen that must appear (empty = unverified)
    note*: string

proc runStep(u: var Ui; o: Opts; s: Step; n: int): bool =
  echo ""
  echo "step " & $n & ": press '" & s.text & "' under '" & s.root & "'"
  if s.note.len > 0: echo "        " & s.note
  if o.dryRun:
    echo "        (dry run -- nothing pressed)"
    return true
  var e = noExpect()
  if s.wantScreen.len > 0:
    e = Expect(kind: xkScreen, name: s.wantScreen, root: "Menu UI")
  let r = clickText(u, s.text, s.root, false, "", e, o.settleMs, true)
  if r.ok: echo "        OK: " & r.msg
  else: echo "        FAILED: " & r.msg
  result = r.ok

proc cmdRaid*(args: seq[string]): int =
  var o = defaultOpts()
  var bad = ""
  for a in args:
    if a == "--help" or a == "-h":
      echo RaidUsage
      return 0
  if not parseOpts(args, o, bad):
    echo "!! " & bad
    return 1
  if o.insurance:
    # Honest refusal beats a step that presses NEXT and calls it insurance.
    echo "!! --insurance is refused: the item-selection procedure for the " &
         "insurance screen has never been measured, so this tool cannot " &
         "drive it. Drop the flag to skip insurance, or drive that one " &
         "screen by hand with `aowl ui click ... --root \"Menu UI\"`."
    return 1
  var u = initUi(o.live, o.timeoutMs, o.timeoutPinned)

  echo "aowl raid -- map '" & o.map & "', insurance SKIPPED."
  echo "precondition: the main menu must already be up. The mode selector " &
       "and profile select are not driven from here; run " &
       "`python tools\\entergame.py` first if you are still on them."

  var steps: seq[Step] = @[]
  steps.add Step(text: "ESCAPE FROM TARKOV", root: "Common UI",
                 wantScreen: "",
                 note: "MenuScreen/PlayButton, actuated via DefaultUIButton. " &
                       "No screen is asserted here because the screen this " &
                       "produces has not been measured -- the result will " &
                       "say UNVERIFIED, and mean it.")
  steps.add Step(text: "NEXT", root: "Menu UI",
                 wantScreen: "Matchmaker Location Selection", note: "")
  steps.add Step(text: o.map, root: "Menu UI", wantScreen: "",
                 note: "an AnimatedToggle -- actuated through " &
                       "Toggle::set_isOn, never `press`. A toggle SELECTS; " &
                       "it does not advance the screen, so no transition is " &
                       "expected and none is asserted.")
  steps.add Step(text: "NEXT", root: "Menu UI",
                 wantScreen: "Matchmaker Offline Raid Screen", note: "")

  var n = 1
  for i in 0 ..< steps.len:
    if not runStep(u, o, steps[i], n):
      echo ""
      echo "STOPPED at step " & $n & ". Nothing further was pressed."
      return 4
    inc n

  # ------------------------------------------------------------------ step 5
  # PRACTICE MODE -- deliberately NOT automated.
  #
  # The label is at Content/NonLayoutContainer/SoloModeCheckmarkBlocker/Label
  # and none of the four known pressable types is on it or its five nearest
  # ancestors; `component <go> Toggle` FAULTS, and the session fault budget is
  # eight, after which the inspector disables itself for good (fact #56). So
  # this does not brute-force component types. Component ENUMERATION is being
  # built elsewhere; this is the hook it plugs into.
  echo ""
  echo "step " & $n & ": 'Enable practice mode for this raid'"
  if o.practice:
    echo "        NOT AUTOMATABLE YET, and nothing was attempted."
    echo "        The label is at Content/NonLayoutContainer/" &
         "SoloModeCheckmarkBlocker/Label. None of " &
         "DefaultUIButton/SimpleStateButton/AnimatedToggle/Button is on it " &
         "or its 5 nearest ancestors, and `component <go> Toggle` FAULTS. " &
         "Guessing further types would burn the inspector's 8-fault budget " &
         "and switch it off for the session, so this stops instead."
    echo "        TICK IT BY HAND NOW, then press Enter."
    var ignored = ""
    discard readLine(stdin, ignored)
  else:
    echo "        skipped (pass --practice to be prompted to tick it by hand)."
  inc n

  var tail: seq[Step] = @[]
  tail.add Step(text: "NEXT", root: "Menu UI",
                wantScreen: "Matchmaker Insurance", note: "")
  tail.add Step(text: "NEXT", root: "Menu UI",
                wantScreen: "MatchMaker AcceptScreen",
                note: "insurance is skipped by advancing past it.")
  tail.add Step(text: "READY", root: "Menu UI", wantScreen: "",
                note: "actuates NextButton. No screen is asserted: what " &
                      "follows is a load, not a screen.")
  for i in 0 ..< tail.len:
    if not runStep(u, o, tail[i], n):
      echo ""
      echo "STOPPED at step " & $n & ". Nothing further was pressed."
      return 4
    inc n

  if o.dryRun:
    echo ""
    echo "dry run complete -- nothing was pressed."
    return 0

  echo ""
  echo "waiting for the raid to load. This is slow, and THE SERVER STARTING " &
       "IS NOT THE RAID STARTING -- the RegisterPlayer counter fires at " &
       "server start, so it is not used as the signal here."
  let e = Expect(kind: xkNoRoot, name: "Menu UI", root: "Menu UI")
  if waitUntil(u, e, o.loadMs, 5000):
    echo "IN RAID: the `Menu UI` scene root is gone, which on this build is " &
         "positive evidence the menu unloaded for a raid."
    return 0
  echo "TIMED OUT after " & $(o.loadMs div 1000) & "s: `Menu UI` is still " &
       "loaded. That is a measured timeout and NOT proof the raid failed -- " &
       "check the client and `aowl ui inraid`."
  result = 4
