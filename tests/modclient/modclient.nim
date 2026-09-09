## modclient -- the *manager's* half of the client host's outcome report.
##
## `tests/modreport` drives the producer: `host/common/modcontrol.nim` builds the
## query string the client host hangs on its poll. This drives the consumer:
## `mods/manager/mgr/clientreport.nim`, which reads that query string and is
## what turns `live`, `restart` and `running` on the panel from the server's
## guess about a process it cannot see into something it was told.
##
## No backend, no host, no socket. `clientreport` deliberately imports nothing
## and takes what the server knows as arguments, so every case below is a
## function call -- including the ones a running game cannot be made to produce
## on demand: a report cut off mid-rotation, a host that restarts under a
## different process id, a code slug from a host newer than this manager.
##
## **The check this file exists for** is the group headed "absence is not off".
## The wire has no encoding for "no answer yet": a guid with no record is
## unknown, and `more=1`, an old host, a host that has not polled yet and a
## record thrown away for being malformed all converge on that same absence. A
## manager that renders it as "no" is wrong by construction, and this project
## has shipped that exact collapse twice. Break `liveVerdict` so that an
## unanswered client-side mod reads `lvStopped` and those checks fail; nothing
## else in the gate does.
##
## To run it alone:
##
##   nimony c --passC:-I<repo>\abi -p:<repo>\mods\manager\mgr
##            -p:<repo>\installer\src -p:<repo>\aowl\src
##            -o:modclient.exe modclient.nim
##
## The `-p:mods\manager\mgr` is the whole dependency. If that ever stops being
## true -- if this module grows an `import aowlspt` -- the thing to fix is the
## module, not this line: a decision that can only be tested inside a running
## backend is a decision that stops being tested.

import std/syncio
import clientreport

var fails = 0
proc check(what: string; cond: bool) =
  if cond:
    echo "ok   ", what
  else:
    echo "FAIL ", what
    fails = fails + 1

# `hs` is 1..16 of [0-9a-f]; two of them, so a restart can be told from a
# re-send.
const S1 = "a1b2c3d4"
const S2 = "ffff0000"

# ---------------------------------------------------------------------------
# Nothing has been said
# ---------------------------------------------------------------------------

check("with no poll at all, no client host is reporting", not clientReporting())
check("with no poll at all, no guid is known", not clientKnows("aowl.one"))
check("a bare poll carries no report", not ingestClientReport(""))
check("a bare poll still leaves nothing known", not clientReporting())
check("a bare poll is counted, so silence can be told from absence",
      clientBarePolls() == 1)

# A poll whose session cannot be a session. Rejected whole rather than partly:
# every row in a report is scoped to the process the report names, and a report
# that does not name one cannot be scoped at all.
check("a poll with no hs is not a report",
      not ingestClientReport("sq=1&r=aowl.one~+n"))
check("an hs that is not hex is refused",
      not ingestClientReport("hs=zzz&sq=1&r=aowl.one~+n"))
check("an hs longer than sixteen is refused",
      not ingestClientReport("hs=00000000000000000&sq=1&r=aowl.one~+n"))
check("an uppercase hs is refused",
      not ingestClientReport("hs=DEADBEEF&sq=1&r=aowl.one~+n"))
check("none of those made anything known", not clientKnows("aowl.one"))
check("and none of them started a session", not clientReporting())

# ---------------------------------------------------------------------------
# The five outcomes
# ---------------------------------------------------------------------------

check("a settled row is taken",
      ingestClientReport("hs=" & S1 & "&sq=0&r=aowl.one~+n"))
check("a session is now reporting", clientReporting())
check("the session is the one on the wire", clientSession() == S1)
check("the sequence is read", clientSeq() == 0 and clientSeqKnown())
check("`n` with `+` means it is running", clientKnows("aowl.one") and
      clientRunning("aowl.one"))
check("`n` is settled", clientSettled("aowl.one"))
check("a settled row is not a disagreement", not clientDisagrees("aowl.one"))
check("a settled row needs no restart", not clientNeedsRestart("aowl.one"))
check("a settled row has nothing to say", clientMessage("aowl.one") == "")

discard ingestClientReport("hs=" & S1 & "&sq=1&r=aowl.one~-n")
check("`n` with `-` means it is not running", not clientRunning("aowl.one"))
check("and it is still settled -- that is what was asked for",
      clientSettled("aowl.one") and not clientDisagrees("aowl.one"))

discard ingestClientReport("hs=" & S1 & "&sq=2&r=aowl.one~+k")
check("`k` with `+` means it is running", clientRunning("aowl.one"))
check("`k` is settled too: it is `n` plus 'and I just moved it'",
      clientSettled("aowl.one"))
check("`k` is not a disagreement", not clientDisagrees("aowl.one"))
discard ingestClientReport("hs=" & S1 & "&sq=3&r=aowl.one~-k")
check("`k` with `-` means it is not running", not clientRunning("aowl.one"))

discard ingestClientReport("hs=" & S1 & "&sq=4&r=aowl.one~+s~nofile")
check("`s` with `+` means it is not running -- it was never attempted",
      not clientRunning("aowl.one"))
check("`s` is not settled", not clientSettled("aowl.one"))
check("`s` is a disagreement", clientDisagrees("aowl.one"))
check("`s` is not a restart: restarting will not install the file",
      not clientNeedsRestart("aowl.one"))
check("the code is kept", clientCodeOf("aowl.one") == "nofile")
check("and it is turned into a sentence about the client",
      clientMessage("aowl.one").len > 0)

discard ingestClientReport("hs=" & S1 & "&sq=5&r=aowl.one~+r~loadfailed")
check("`r` with `+` means it is not running", not clientRunning("aowl.one"))
check("`r` is a disagreement", clientDisagrees("aowl.one"))
check("`r` is not a restart -- it will be refused after one too",
      not clientNeedsRestart("aowl.one"))

discard ingestClientReport("hs=" & S1 & "&sq=6&r=aowl.one~-d~noteardown")
check("`d` with `-` means it is still running", clientRunning("aowl.one"))
check("`d` is a disagreement", clientDisagrees("aowl.one"))
check("`d` is the one outcome a restart fixes",
      clientNeedsRestart("aowl.one"))
check("the outcome is named for a reader",
      clientOutcomeName(clientOutcomeOf("aowl.one")) == "on-restart")
check("and it round-trips back to its letter",
      clientOutcomeLetter(clientOutcomeOf("aowl.one")) == "d")

# ---------------------------------------------------------------------------
# What is refused, and what a refusal costs
# ---------------------------------------------------------------------------

forgetClientReport()
discard ingestClientReport("hs=" & S1 &
  "&sq=1&r=aowl.good~+n!broken!aowl.also~-n!~+n!aowl.bad~+q!aowl.third~+n")
check("a malformed record does not take its neighbours with it",
      clientKnows("aowl.good") and clientKnows("aowl.also") and
      clientKnows("aowl.third"))
check("a record with no state is dropped", not clientKnows("broken"))
check("a record with an empty guid is dropped", clientRows() == 3)
check("an outcome letter this manager does not know leaves the mod unknown",
      not clientKnows("aowl.bad"))

forgetClientReport()
discard ingestClientReport("hs=" & S1 & "&sq=1&r=aowl.one~+n~nofile")
check("a code on a settled row is dropped rather than kept",
      clientKnows("aowl.one") and clientCodeOf("aowl.one") == "")
check("dropping it does not cost the record",
      clientRunning("aowl.one"))

forgetClientReport()
discard ingestClientReport("hs=" & S1 & "&sq=1&r=aowl.one~+s~sometimenew")
check("a code slug from a newer host is kept as text",
      clientCodeOf("aowl.one") == "sometimenew")
check("a slug this manager cannot explain is quoted, never paraphrased",
      clientMessage("aowl.one") == "the client host did not try -- " &
      "the client host says: sometimenew")
check("and it is not pretended to be one of the known set",
      not knownCode("sometimenew") and knownCode("nofile"))

forgetClientReport()
discard ingestClientReport("hs=" & S1 & "&sq=1&r=aowl.one%2etwo~+n")
check("a guid carrying an escape the host never emits is not a guid",
      not clientKnows("aowl.one%2etwo"))

# ---------------------------------------------------------------------------
# Absence is not "off"
# ---------------------------------------------------------------------------
#
# The group this file is for. Every check here fails if a guid with no record
# is allowed to mean "not running", which is the one thing the wire has no way
# of saying and the one mistake this protocol is shaped to prevent.

forgetClientReport()

# A client-only mod: `sides` has no server in it, so the server's inventory is
# not an answer about it however complete that inventory is.
check("with no record at all, a client-only mod is unknown -- not stopped",
      liveVerdict("aowl.clientonly", true, false, false, true) == lvUnknown)
check("a mod that runs on both sides, absent from the server and unmentioned " &
      "by the client, is unknown",
      liveVerdict("aowl.both", true, false, true, true) == lvUnknown)
check("a server-only mod the server has listed is stopped: the only host " &
      "that could answer has",
      liveVerdict("aowl.serveronly", true, false, true, false) == lvStopped)
check("before the server has listed, even a server-only mod is unknown",
      liveVerdict("aowl.serveronly", false, false, true, false) == lvUnknown)

# The same mod, now with a report in hand.
discard ingestClientReport("hs=" & S1 & "&sq=1&r=aowl.clientonly~+n")
check("a client-only mod the client says is running reads running",
      liveVerdict("aowl.clientonly", true, false, false, true) == lvRunning)
discard ingestClientReport("hs=" & S1 & "&sq=2&r=aowl.clientonly~-n")
check("a client-only mod the client says is not running reads stopped",
      liveVerdict("aowl.clientonly", true, false, false, true) == lvStopped)
check("and that is a thing the server alone could never have said",
      liveVerdict("aowl.neverheard", true, false, false, true) == lvUnknown)

discard ingestClientReport("hs=" & S1 & "&sq=3&r=aowl.both~-n")
check("a both-sides mod needs both answers before it may read stopped",
      liveVerdict("aowl.both", true, false, true, true) == lvStopped)
check("and the client alone is not enough while the server is silent",
      liveVerdict("aowl.both", false, false, true, true) == lvUnknown)
discard ingestClientReport("hs=" & S1 & "&sq=4&r=aowl.both~+n")
check("either host saying it is running is enough to say it is running",
      liveVerdict("aowl.both", false, false, true, true) == lvRunning)
check("the server saying so is enough even when the client says otherwise: " &
      "it is loaded, in a process, and the row must not be greyed",
      liveVerdict("aowl.other", true, true, true, true) == lvRunning)

check("an unknown mod is not a disagreement either",
      not clientDisagrees("aowl.neverheard"))
check("nor does an unknown mod ask for a restart",
      not clientNeedsRestart("aowl.neverheard"))
check("nor does it have anything to say",
      clientMessage("aowl.neverheard") == "")

# ---------------------------------------------------------------------------
# `more=1`: the rows that did not fit
# ---------------------------------------------------------------------------

forgetClientReport()
discard ingestClientReport("hs=" & S1 & "&sq=9&r=aowl.one~+n!aowl.two~+n")
check("two rows, both known", clientRows() == 2)
discard ingestClientReport("hs=" & S1 & "&sq=9&r=aowl.three~+n&more=1")
check("a truncated report adds what it carries", clientKnows("aowl.three"))
check("and leaves what it did not mention exactly as it was",
      clientKnows("aowl.one") and clientKnows("aowl.two"))
check("the truncation is remembered, so a reader can say why a row is " &
      "unknown", clientMore())
check("a guid the rotation has not reached yet is unknown, not off",
      liveVerdict("aowl.four", true, false, false, true) == lvUnknown)

# And the complete report that follows it.
discard ingestClientReport("hs=" & S1 & "&sq=9&r=aowl.one~+n!aowl.three~+n")
check("a complete report is the whole ledger, so the rows it leaves out are " &
      "rows the host has dropped",
      not clientKnows("aowl.two"))
check("the rows it does carry survive",
      clientKnows("aowl.one") and clientKnows("aowl.three"))
check("a dropped row is unknown rather than stopped",
      liveVerdict("aowl.two", true, false, false, true) == lvUnknown)
check("and the truncation flag is cleared with it", not clientMore())

# ---------------------------------------------------------------------------
# A new process
# ---------------------------------------------------------------------------

discard ingestClientReport("hs=" & S2 & "&sq=0&r=aowl.one~-n")
check("a different hs is a different game, and the session moves",
      clientSession() == S2)
check("everything held about the old process is dropped",
      not clientKnows("aowl.three"))
check("a mod the new process has not mentioned is unknown, whatever the old " &
      "one said about it",
      liveVerdict("aowl.three", true, false, false, true) == lvUnknown)
check("what the new process did say is held",
      clientKnows("aowl.one") and not clientRunning("aowl.one"))
check("the sequence starts over with the process", clientSeq() == 0)

# ---------------------------------------------------------------------------
# Re-sends, and a sequence that does not parse
# ---------------------------------------------------------------------------

discard ingestClientReport("hs=" & S2 & "&sq=1&r=aowl.one~+k")
let saidOnce = clientRunning("aowl.one")
discard ingestClientReport("hs=" & S2 & "&sq=1&r=aowl.one~+k")
check("the same sq twice is a re-send, and says the same thing",
      clientRunning("aowl.one") == saidOnce and clientRows() == 1)
check("a re-send is still counted as a report", clientReports() > 0)

discard ingestClientReport("hs=" & S2 & "&sq=notanumber&r=aowl.one~+n")
check("a sequence that does not parse leaves the last one that did",
      clientSeq() == 1)
check("and the records in that report are still taken",
      clientSettled("aowl.one"))

# ---------------------------------------------------------------------------
# The query is read as a query, not as a string that happens to contain one
# ---------------------------------------------------------------------------

forgetClientReport()
discard ingestClientReport("r=aowl.one~+n&hs=" & S1 & "&sq=2")
check("the order of the keys does not matter", clientKnows("aowl.one"))
discard ingestClientReport("hs=" & S1 & "&sq=3&x=1&r=aowl.two~+n&y=2")
check("a key this manager does not know is ignored, not fatal",
      clientKnows("aowl.two"))
discard ingestClientReport("hs=" & S1 & "&sq=4&r=")
check("an empty record list is a complete report of nothing",
      clientRows() == 0 and clientReporting())
check("which is not the same as no session", clientSession() == S1)

# ---------------------------------------------------------------------------
# The table cannot be grown without bound by whoever can reach the route
# ---------------------------------------------------------------------------
#
# `more=1` merges, and merging is an unbounded `add` driven by the caller. The
# route is on the loopback, so the bound is a property of this module rather
# than of who would.

forgetClientReport()
var flood = "hs=" & S1 & "&sq=1&more=1&r="
var made = 0
while made < 400:
  if made > 0:
    flood = flood & "!"
  flood = flood & "aowl.flood" & $made & "~+n"
  made = made + 1
discard ingestClientReport(flood)
check("one report cannot state more rows than the wire could carry",
      clientRows() <= 128)
var round = 0
while round < 8:
  var part = "hs=" & S1 & "&sq=" & $(round + 2) & "&more=1&r="
  var k = 0
  while k < 100:
    if k > 0:
      part = part & "!"
    part = part & "aowl.more" & $round & "x" & $k & "~+n"
    k = k + 1
  discard ingestClientReport(part)
  round = round + 1
check("and a stream of truncated reports cannot grow the table without bound",
      clientRows() <= 256)
check("the rows it does hold are still readable",
      clientKnows("aowl.flood0") and clientRunning("aowl.flood0"))
check("a guid refused for the cap is unknown, not off",
      liveVerdict("aowl.more7x99", true, false, false, true) == lvUnknown)

if fails == 0:
  echo "all checks passed"
else:
  echo $fails & " checks failed"
