## What the **client** host says came of a request — the manager's half.
##
## `mgr/control.nim` is the other host: the one in this process, reached by
## events, which answers `aowlspt.host.mods.result` and whose answers land in a
## table this manager keeps. The client host is in `EscapeFromTarkov.exe` and no
## event will ever reach it, so it polls `/aowlspt/mods/client/<hostver>`
## instead — and it now says, on that same poll, what actually became of the set
## it was last given:
##
##     GET /aowlspt/mods/client/<hostver>?hs=<sid>&sq=<n>&r=<records>[&more=1]
##
##     hs   this host *process*, 1..16 of [0-9a-f]. Constant for one run of the
##          game. A different `hs` means every outcome held here is about a
##          process that no longer exists, and all of it drops back to unknown.
##     sq   decimal from 0, +1 on every real change to any row. The same `sq`
##          twice is a re-send, not new intent.
##     r    records joined by `!`, each `<guid>~<want><outcome>[~<code>]`
##            <want>     `+` should be loaded, `-` should be unloaded
##            <outcome>  `n` nothing to do, already in that state
##                       `k` attempted and it worked
##                       `s` **not attempted**; `code` says why
##                       `r` attempted, refused, and refused after a restart too
##                       `d` attempted, refused *live*; holds on restart
##            <code>     a slug from the closed set below, only on `s`/`r`/`d`
##     more `1` when the rows did not all fit in the path. The rest arrive on
##          later polls; the host rotates, so nothing is starved and no
##          acknowledgement is needed.
##
## The wire is written down in full at the head of `host/common/modcontrol.nim`,
## which is the side that produces it. This module only ever *reads* it.
##
## ---------------------------------------------------------------------------
## The one rule everything here is arranged around
## ---------------------------------------------------------------------------
##
## **There is deliberately no encoding for "no answer yet".** A guid with no
## record is a guid this host has not answered about. `more=1`, a host that has
## not polled, a host too old to report at all, a record dropped for being
## malformed — all of them converge on *absence*, and absence is unknown. Never
## "no", never "off", never "not running".
##
## So every accessor below that can narrow a mod's state comes in two parts: one
## that says whether there is a record, and one that reads it. `clientRunning`
## is meaningless — and documented as meaningless — unless `clientKnows` is true
## first, and `liveVerdict` is the proc callers are meant to use precisely
## because it cannot be asked the question without also being told what is
## known. This project has shipped the collapse of those two twice; the shape of
## this module is what stops it happening a third time.
##
## A second consequence, less obvious: a record is *merged*, never used to
## rebuild the table. A poll that carries three rows out of nine is a poll that
## said nothing about the other six, and clearing them would turn the host's
## rotation into six mods flickering to unknown and back forever.
##
## The exception, and it is the only one: a report **without** `more=1` is the
## host's whole ledger, because the host sets that flag whenever a row did not
## fit. Rows this manager holds that a complete report does not mention are rows
## the host has dropped — `forgetOutcomes` does that for guids the backend has
## stopped naming — and keeping them would leave a verdict on the panel about a
## mod the registry no longer resolves for that side. Those go back to unknown,
## which is what they are.
##
## ---------------------------------------------------------------------------
## Why the derivation lives here and not in `manager.nim`
## ---------------------------------------------------------------------------
##
## "Is it running?" has two hosts in it. The server's answer is
## `control.liveKnown()` / `control.isLive()`; the client's is the ledger above;
## and which of them is entitled to answer depends on the sides the registry
## declares for the mod. That is four inputs and three outcomes, it is where the
## absence rule is actually enforced, and it is the sort of thing that is either
## a pure function with every case written out or a lie in a route handler.
## `liveVerdict` is the function. It takes what the server knows rather than
## importing `control`, so it can be driven exhaustively from a test with no
## host, no backend and no registry under it.
##
## ---------------------------------------------------------------------------
## Locking
## ---------------------------------------------------------------------------
##
## Every proc here assumes the manager's mod lock is **already held**, like the
## readers in `mgr/control.nim` and for the same reason: the only writer is
## `routeClient`, which is a route, and every reader is a route as well. Nothing
## here takes the lock, and nothing here may — it is documented non-reentrant.

type
  ClientOutcome* = enum
    ## The closed set, plus the one that is never on the wire.
    ##
    ## `coUnknown` is not a state the host can report. It is what this manager
    ## holds about a guid it has heard nothing about, and it is the reason the
    ## enum exists at all rather than a bool pair.
    coUnknown
    coNoop      ## `n` — nothing to do; it was already in that state
    coOk        ## `k` — attempted, and it worked
    coSkipped   ## `s` — not attempted; the code says why
    coRefused   ## `r` — attempted and refused, live and on restart alike
    coDeferred  ## `d` — refused live; the change holds on restart

  LiveVerdict* = enum
    ## What may be said about a mod on the panel's `live` column.
    lvUnknown   ## nobody entitled to answer has answered. Render as null.
    lvRunning
    lvStopped

const
  ## The closed set of reasons, as `host/common/modcontrol.nim` spells them.
  ## A slug outside this set is kept as text and rendered verbatim but is never
  ## given a sentence: a manager that invented an explanation for a code it does
  ## not know would be putting a future host's words in its own mouth.
  CodeNoArtifact* = "noartifact"
  CodeNoFile* = "nofile"
  CodeNoPath* = "nopath"
  CodeMissing* = "missing"
  CodeWrongGuid* = "wrongguid"
  CodeLoadFailed* = "loadfailed"
  CodeNoTeardown* = "noteardown"
  CodeUnloadFailed* = "unloadfailed"

  MaxSessionLen = 16
    ## As the wire says: 1..16 of [0-9a-f]. Longer is not a longer session id,
    ## it is a malformed one, and a malformed one cannot scope anything.
  MaxGuidLen = 80
    ## The overlay's row keys this by guid in an 80-byte field, and a guid this
    ## manager could never draw is one it has no use for. It also bounds what a
    ## bad report can make this table cost.
  MaxCodeLen = 24
  MaxRecords = 128
    ## One poll cannot say more than this. The path it rides on is capped at 191
    ## characters, so a report with a hundred and twenty-eight records in it did
    ## not come from the host this parser is written against.
  MaxRows = 256
    ## And the table as a whole cannot grow past this.
    ##
    ## A `more=1` report is merged rather than replacing the table, which is the
    ## whole point of it -- and that is also an unbounded `add` driven by
    ## whoever can reach the route. Anything on the loopback can, so the bound
    ## is here rather than in an argument about who would. A row refused for the
    ## cap is a mod left unknown, which is the safe answer and the same answer
    ## every other refusal in this file gives.

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------
#
# Parallel seqs and index loops, which is the style `mgr/control.nim` is written
# in: binding a loop variable to an element of a `seq[object]` and then reading
# a field of a nested seq miscompiles in nimony, and one style throughout is
# easier to trust than two. Nothing here removes an element in place — nimony's
# seq has no `delete` — so the two places that drop rows rebuild the four seqs
# together.

var gSession = ""
var gSeq = -1
var gSeqKnown = false
var gMore = false
var gReports = 0
var gBarePolls = 0
var gSessions = 0
var gBotNavCensus = ""
  ## The client host's live bot registry as of its last poll, verbatim:
  ## `id,role,difficulty,alive,x,y,z,lastNavStatus` per bot, `!`-separated. Held
  ## as the raw string rather than parsed into rows because every consumer so far
  ## wants either the whole thing or one field of one bot, and a parse here would
  ## be a second place for the format to drift.
var gBotNavCensusAt = 0
  ## How many censuses have arrived. A caller can tell "no bots in the raid"
  ## (count > 0, census empty) from "no host has ever reported" (count == 0),
  ## which are very different answers to "where are the bots".
var gGuid: seq[string] = @[]
var gWant: seq[bool] = @[]
var gOut: seq[ClientOutcome] = @[]
var gCode: seq[string] = @[]

proc clientIndexOf(guid: string): int =
  result = -1
  for i in 0 ..< gGuid.len:
    if gGuid[i] == guid:
      return i

proc dropAll() =
  gGuid = @[]
  gWant = @[]
  gOut = @[]
  gCode = @[]

proc putRow(guid: string; want: bool; outcome: ClientOutcome; code: string) =
  let at = clientIndexOf(guid)
  if at >= 0:
    gWant[at] = want
    gOut[at] = outcome
    gCode[at] = code
    return
  if gGuid.len >= MaxRows:
    return
  gGuid.add guid
  gWant.add want
  gOut.add outcome
  gCode.add code

# ---------------------------------------------------------------------------
# Reading one record
# ---------------------------------------------------------------------------

proc isHexId(s: string): bool =
  if s.len == 0 or s.len > MaxSessionLen:
    return false
  for ch in s:
    if not ((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f')):
      return false
  result = true

proc isGuidText(s: string): bool =
  ## The characters the host's `urlSafe` can emit, and nothing else. It drops
  ## anything outside that set rather than escaping it, so a guid that arrives
  ## with a stray character is not a guid it mangled — it is a guid this manager
  ## does not know, which reads as unknown, which is the safe answer.
  if s.len == 0 or s.len > MaxGuidLen:
    return false
  for ch in s:
    if not ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '_'):
      return false
  result = true

proc isCodeText(s: string): bool =
  if s.len == 0 or s.len > MaxCodeLen:
    return false
  for ch in s:
    if not ((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9')):
      return false
  result = true

proc clientOutcomeOfLetter*(ch: char): ClientOutcome =
  ## An unlisted letter is `coUnknown` — which is *absence*, not a sixth state.
  ## A host newer than this manager may one day send a letter that is not here,
  ## and the mod it is about has to stay unknown rather than be guessed at.
  if ch == 'n': return coNoop
  if ch == 'k': return coOk
  if ch == 's': return coSkipped
  if ch == 'r': return coRefused
  if ch == 'd': return coDeferred
  result = coUnknown

proc clientOutcomeLetter*(o: ClientOutcome): string =
  if o == coNoop: return "n"
  if o == coOk: return "k"
  if o == coSkipped: return "s"
  if o == coRefused: return "r"
  if o == coDeferred: return "d"
  result = ""

proc clientOutcomeName*(o: ClientOutcome): string =
  if o == coNoop: return "settled"
  if o == coOk: return "changed"
  if o == coSkipped: return "skipped"
  if o == coRefused: return "refused"
  if o == coDeferred: return "on-restart"
  result = "unknown"

proc clientTakesCode*(o: ClientOutcome): bool =
  ## Only `s`, `r` and `d` carry one. A code on `n` or `k` is a record from
  ## something that is not the host this parses, and the code is dropped rather
  ## than kept: "it worked, because nofile" is not a sentence.
  result = o == coSkipped or o == coRefused or o == coDeferred

proc knownCode*(code: string): bool =
  result = code == CodeNoArtifact or code == CodeNoFile or
           code == CodeNoPath or code == CodeMissing or
           code == CodeWrongGuid or code == CodeLoadFailed or
           code == CodeNoTeardown or code == CodeUnloadFailed

proc cutAt(s: string; sep: char; head, tail: var string): bool =
  ## `s` split at the first `sep`. False when there is none, and `head` is then
  ## the whole string — hand-rolled because nimony's strutils has no `rfind` and
  ## this needs first-occurrence semantics in three places.
  head = s
  tail = ""
  for i in 0 ..< s.len:
    if s[i] == sep:
      head = s.substr(0, i - 1)
      tail = s.substr(i + 1)
      return true
  result = false

proc parseRecord*(rec: string; guid: var string; want: var bool;
                  outcome: var ClientOutcome; code: var string): bool =
  ## `<guid>~<want><outcome>[~<code>]`, or false and nothing written.
  ##
  ## Every rejection here leaves the mod it was about *unknown*, which is why
  ## the parser can afford to be strict: the cost of refusing a record is that
  ## the manager keeps saying "I do not know", and the cost of accepting a
  ## malformed one is that it says something it cannot support.
  guid = ""
  want = false
  outcome = coUnknown
  code = ""
  var g = ""
  var rest = ""
  if not cutAt(rec, '~', g, rest):
    return false
  if not isGuidText(g):
    return false
  var state = ""
  var slug = ""
  if not cutAt(rest, '~', state, slug):
    state = rest
    slug = ""
  if state.len != 2:
    return false
  if state[0] == '+':
    want = true
  elif state[0] == '-':
    want = false
  else:
    return false
  let o = clientOutcomeOfLetter(state[1])
  if o == coUnknown:
    return false
  if slug.len > 0:
    if not isCodeText(slug):
      return false
    if not clientTakesCode(o):
      # Dropped rather than refused: the outcome is still a letter this manager
      # understands, and losing the whole record over a code that cannot apply
      # to it would trade a fact for nothing.
      slug = ""
  guid = g
  outcome = o
  code = slug
  result = true

# ---------------------------------------------------------------------------
# Reading one report
# ---------------------------------------------------------------------------

proc queryValue(query: string; key: string; value: var string): bool =
  ## The first `key=` in `query`, which is `&`-separated. First rather than last
  ## because a repeated key is a malformed report and the only thing that
  ## matters is that two managers reading it agree.
  value = ""
  var i = 0
  while i < query.len:
    var j = i
    while j < query.len and query[j] != '&':
      inc j
    let part = query.substr(i, j - 1)
    var k = ""
    var v = ""
    if cutAt(part, '=', k, v):
      if k == key:
        value = v
        return true
    elif part == key:
      # `&more` with no `=1`. Not something the host emits, and taken as the
      # empty value rather than as absence so that a caller testing for the key
      # is not told the key is missing.
      value = ""
      return true
    i = j + 1
  result = false

proc ingestClientReport*(query: string): bool =
  ## Take one poll's report. `query` is everything after the `?`, and the empty
  ## string is the ordinary case: a host with nothing to say, or one built
  ## before any of this existed, polls the bare route.
  ##
  ## Returns true when a report was actually taken, which is *not* the same as
  ## "the poll happened" — a caller must not read the answer as anything about
  ## the mods.
  ##
  ## Assumes the mod lock is held.

  # The bot-navigation census is read FIRST, deliberately before the session
  # gate below. It is a plain state -- "these bots are alive at these positions
  # right now" -- with no sequence number, no rotation and nothing to
  # acknowledge, so none of the session bookkeeping applies to it. It also has
  # to survive the case that has no `hs` at all: a host with the nav API on but
  # no mod-outcome rows to report appends `?bn=...` to the bare route, and
  # reading it after the `hs` bail would silently throw away every census such a
  # host ever sends. Losing one costs nothing anyway -- the next poll carries the
  # current truth -- but losing all of them would make the feature look broken.
  var census = ""
  if queryValue(query, "bn", census):
    gBotNavCensus = census
    gBotNavCensusAt = gBotNavCensusAt + 1

  var hs = ""
  if not queryValue(query, "hs", hs) or not isHexId(hs):
    # A poll with no session, or with one that cannot be a session. Counted,
    # because "the client host is polling and saying nothing" and "the client
    # host is not polling" are different problems and the panel should be able
    # to tell them apart — but nothing is narrowed by it.
    inc gBarePolls
    return false

  if hs != gSession:
    # A different process. Everything held is about one that no longer exists,
    # and a manager drawing it against the client running now would be reporting
    # a fact about a dead process — the same class of lie as guessing, with the
    # added charm of looking authoritative.
    dropAll()
    gSession = hs
    gSeq = -1
    gSeqKnown = false
    gMore = false
    inc gSessions

  var sqText = ""
  if queryValue(query, "sq", sqText):
    var n = 0
    var ok = sqText.len > 0
    for ch in sqText:
      if ch < '0' or ch > '9':
        ok = false
      else:
        n = n * 10 + (ord(ch) - ord('0'))
        if n > 1000000000:
          ok = false
    if ok:
      gSeq = n
      gSeqKnown = true

  var moreText = ""
  let more = queryValue(query, "more", moreText) and moreText == "1"
  gMore = more

  var records = ""
  discard queryValue(query, "r", records)

  # Merged, never rebuilt. See the head of this file: a poll carrying three rows
  # out of nine said nothing about the other six.
  var seen: seq[string] = @[]
  var i = 0
  var taken = 0
  while i < records.len and taken < MaxRecords:
    var j = i
    while j < records.len and records[j] != '!':
      inc j
    let rec = records.substr(i, j - 1)
    i = j + 1
    var guid = ""
    var want = false
    var outcome = coUnknown
    var code = ""
    if not parseRecord(rec, guid, want, outcome, code):
      continue
    putRow(guid, want, outcome, code)
    seen.add guid
    inc taken

  if not more:
    # A complete report is the host's whole ledger, so a row it does not mention
    # is a row it has dropped. Rebuilt rather than deleted in place: nimony's
    # seq cannot shrink.
    var ng: seq[string] = @[]
    var nw: seq[bool] = @[]
    var no: seq[ClientOutcome] = @[]
    var nc: seq[string] = @[]
    for k in 0 ..< gGuid.len:
      var keep = false
      for g in seen:
        if g == gGuid[k]:
          keep = true
      if keep:
        ng.add gGuid[k]
        nw.add gWant[k]
        no.add gOut[k]
        nc.add gCode[k]
    gGuid = ng
    gWant = nw
    gOut = no
    gCode = nc

  inc gReports
  result = true

proc forgetClientReport*() =
  ## Everything back to unknown. Not called by any route today; it is here
  ## because "drop what you hold" is a thing this table has to be able to do
  ## without a process restart, and a table that can only be added to is one
  ## that will be cleared by hand at the wrong moment.
  dropAll()
  gSession = ""
  gSeq = -1
  gSeqKnown = false
  gMore = false

# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

proc clientSession*(): string = gSession
proc clientSeq*(): int = gSeq
proc clientSeqKnown*(): bool = gSeqKnown
proc clientMore*(): bool = gMore
  ## The last report did not carry every row. The rest arrive on later polls and
  ## nothing has to be asked for; it is here so the panel can say why a mod it
  ## has no record for may yet get one.
proc clientRows*(): int = gGuid.len
proc clientReports*(): int = gReports
proc clientBarePolls*(): int = gBarePolls
proc clientSessions*(): int = gSessions
proc clientBotNav*(): string = gBotNavCensus
proc clientBotNavCount*(): int = gBotNavCensusAt

proc clientReporting*(): bool = gSession.len > 0
  ## A client host has reported at least once in this manager's life. False is
  ## the honest state for a host that has not polled, an older host, and a host
  ## whose every report was malformed.

proc clientKnows*(guid: string): bool =
  ## **Ask this before anything else.** False is "this manager has no record",
  ## which is not a statement about the mod.
  result = clientIndexOf(guid) >= 0

proc clientOutcomeOf*(guid: string): ClientOutcome =
  let at = clientIndexOf(guid)
  if at < 0:
    return coUnknown
  result = gOut[at]

proc clientWants*(guid: string): bool =
  ## What the *client* resolution asked for, which is not what the server's
  ## resolution asked for and must not be compared against it: a client-only mod
  ## is `wrong-side` on the server and `+` here, and both are correct.
  ##
  ## Meaningless unless `clientKnows`.
  let at = clientIndexOf(guid)
  if at < 0:
    return false
  result = gWant[at]

proc clientCodeOf*(guid: string): string =
  let at = clientIndexOf(guid)
  if at < 0:
    return ""
  result = gCode[at]

proc clientRunning*(guid: string): bool =
  ## Whether the mod is loaded in the game right now.
  ##
  ## **Meaningless unless `clientKnows(guid)`** — it answers false for a guid
  ## with no record, and false there would be a lie. Every caller in this
  ## project goes through `liveVerdict`, which cannot be asked without being
  ## told.
  ##
  ## `n` and `k` are the same answer, deliberately. `k` is transient: the tick
  ## after a load or an unload succeeds the mod is simply in the state it was
  ## asked for, and the next poll reports `n`. A manager that read `k` as a
  ## state and `n` as a lesser one would have every successful change appear to
  ## regress one poll later.
  ##
  ## `s`, `r` and `d` all mean the mod is *not* where it was asked to be: the
  ## host only records them for a mod whose live state differs from the wanted
  ## one, and none of the three changed it. So the running state is the opposite
  ## of what was wanted, which is a fact rather than an inference — the host
  ## looked before it said so.
  let at = clientIndexOf(guid)
  if at < 0:
    return false
  let o = gOut[at]
  if o == coNoop or o == coOk:
    return gWant[at]
  result = not gWant[at]

proc clientSettled*(guid: string): bool =
  ## The client is where it was asked to be. False for a guid with no record —
  ## and that false means "not known to be settled", which is why every caller
  ## uses it to *add* a warning rather than to clear one.
  let o = clientOutcomeOf(guid)
  result = o == coNoop or o == coOk

proc clientNeedsRestart*(guid: string): bool =
  ## `d` and only `d`: attempted, refused while the game runs, and the change
  ## holds on the next start. `r` is a refusal a restart does not fix and `s`
  ## was never attempted; both are disagreements, neither is "restart and it
  ## will be so".
  result = clientOutcomeOf(guid) == coDeferred

proc clientDisagrees*(guid: string): bool =
  ## What is running in the game is not what the manager resolved for it. False
  ## for a guid with no record: an unknown row is not a disagreement, and
  ## drawing it as one would put a mark on every client mod the moment a host
  ## with a truncated report polled.
  if not clientKnows(guid):
    return false
  result = clientRunning(guid) != clientWants(guid)

proc clientMessage*(guid: string): string =
  ## The row's sentence, or "" when there is nothing to say. Settled rows say
  ## nothing on purpose: they are the common case, the panel has a `live`
  ## column for them, and a reason field that repeats the column costs bytes out
  ## of a 32 KB body for every row in the registry.
  let at = clientIndexOf(guid)
  if at < 0:
    return ""
  let o = gOut[at]
  if o == coNoop or o == coOk:
    return ""
  let code = gCode[at]
  var why = ""
  if code == CodeNoArtifact:
    why = "the registry gives it no artifact to load"
  elif code == CodeNoFile:
    why = "it is not installed on the client side"
  elif code == CodeNoPath:
    why = "the client host was given no path to load it from"
  elif code == CodeMissing:
    why = "the client loader reported success and left no live mod behind"
  elif code == CodeWrongGuid:
    why = "that library announces a different guid"
  elif code == CodeLoadFailed:
    why = "the client loader refused it; the host log has the reason"
  elif code == CodeNoTeardown:
    why = "that host cannot take any mod out while it runs"
  elif code == CodeUnloadFailed:
    why = "the unload itself failed; the host log has the reason"
  elif code.len > 0:
    why = "the client host says: " & code
  if o == coDeferred:
    result = "the game's host could not do it live"
    if why.len > 0:
      result = result & " -- " & why
    result = result & "; it takes effect when the game restarts"
    return
  if o == coRefused:
    result = "the client host tried and could not"
    if why.len > 0:
      result = result & " -- " & why
    result = result & "; restarting the game will not change that"
    return
  result = "the client host did not try"
  if why.len > 0:
    result = result & " -- " & why

# ---------------------------------------------------------------------------
# The one derivation
# ---------------------------------------------------------------------------

proc liveVerdict*(guid: string; serverKnown, serverLive: bool;
                  runsOnServer, runsOnClient: bool): LiveVerdict =
  ## "Is this mod running?", answered from both hosts at once, or refused.
  ##
  ## The inputs are passed in rather than read: `serverKnown` is
  ## `control.liveKnown()` and `serverLive` is `control.isLive()`, and taking
  ## them as arguments is what lets every one of the cases below be driven from
  ## a test with no host under it. `runsOnServer` / `runsOnClient` are the sides
  ## the registry declares, and they are what decides which host is *entitled*
  ## to answer: a mod that cannot run in the game is fully described by the
  ## server's answer, and a mod that cannot run on the server is fully described
  ## by the client's.
  ##
  ## The order is "a fact beats a silence", and then "two silences are a
  ## silence":
  ##
  ##  1. either host says it is running -> running. A mod loaded anywhere is
  ##     loaded, and `live` on the panel is what stops the row being greyed.
  ##  2. every host that could be running it has said it is not -> stopped.
  ##  3. anything else -> unknown, and the panel draws null, which the overlay
  ##     reads as "leave this row alone" and which preserves whatever the client
  ##     host pushed in about its own process.
  ##
  ## Case 2 is the whole rule in one line: it needs an answer from *each* side
  ## that could have one. A mod that runs on both, listed as absent by the
  ## server and unmentioned by the client, is unknown — because the client is
  ## where it would be running, and nobody asked it.
  let clientSaid = clientKnows(guid)
  if serverKnown and serverLive:
    return lvRunning
  if clientSaid and clientRunning(guid):
    return lvRunning
  let serverAnswered = serverKnown or not runsOnServer
  let clientAnswered = clientSaid or not runsOnClient
  # A mod that declares neither side is not a mod either host would ever load,
  # and the two "answered" flags above are both trivially true for it. That is
  # the right answer -- it is not running -- but it is arrived at by both halves
  # being vacuous, so it is said here rather than left to be noticed.
  if serverAnswered and clientAnswered:
    return lvStopped
  result = lvUnknown

proc liveVerdictName*(v: LiveVerdict): string =
  if v == lvRunning: return "running"
  if v == lvStopped: return "stopped"
  result = "unknown"
