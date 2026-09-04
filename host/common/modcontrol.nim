## The host half of live mod control: loading and unloading mods while the
## game and the server are both running.
##
## `mods/manager` speaks a small request/reply protocol over the ordinary event
## channel, and has done since it was written -- but nothing answered, because
## an event emitted by a mod is delivered to *subscribers* and a host is not a
## subscriber. So the manager degraded to "recorded; takes effect on restart"
## forever. This module is what answers, and it is shared by both hosts because
## the protocol is the same on either side of the wire and two implementations
## of it would drift the way the two JSON path lookups did.
##
## The protocol, verbatim from `mods/manager/mgr/control.nim`:
##
##   `aowlspt.host.mods.probe`   {"from":"<guid>"}
##     -> `aowlspt.host.mods.capabilities`
##        {"host":"...","version":"...","control":true,"load":true,
##         "unload":true,"reloadNeedsRestart":false}
##
##   `aowlspt.host.mods.load`    {"guid":"...","path":"<absolute .dll>"}
##   `aowlspt.host.mods.unload`  {"guid":"..."}
##     -> `aowlspt.host.mods.result`
##        {"guid":"...","action":"load"|"unload","ok":...,"deferred":...,
##         "error":"..."}
##
##   `aowlspt.host.mods.list`    {}
##     -> `aowlspt.host.mods.listed`
##        {"mods":[{"guid","name","version","path","live","hotReloadable"}]}
##
## ---------------------------------------------------------------------------
## The client host's answer, which does not travel on the event channel
## ---------------------------------------------------------------------------
##
## Everything above only works where the manager and the host share a process.
## The client host does not: it polls `/aowlspt/mods/client/<hostver>` for the
## set it should be running, acts, and -- until the ledger further down existed
## -- said nothing back. So the manager's `live` and `restart` verdicts for a
## client-side mod were its own guess about a process it cannot see.
##
## The answer rides the *next poll*, in the query string, because that request
## is already being made and a second channel would need an HTTP client, a
## socket and a thread that this DLL has exactly one of, inside the overlay,
## for the panel:
##
##   GET /aowlspt/mods/client/<hostver>?hs=<sid>&sq=<n>&r=<records>[&more=1]
##
##   hs   this host *process*, 1..16 of [0-9a-f]. Constant for one run of the
##        game. A different `hs` means every outcome held for this host is from
##        a process that no longer exists and drops back to unknown.
##   sq   decimal, from 0, +1 on every real change to any row. The same `sq`
##        twice carries no news -- it is a re-send, not a repetition of intent.
##   r    records joined by `!`, each `<guid>~<want><outcome>[~<code>]`
##          <want>     `+` should be loaded, `-` should be unloaded
##          <outcome>  one letter, closed set:
##                       n  nothing to do; already in that state
##                       k  attempted, and it worked
##                       s  **not attempted**; `code` says why
##                       r  attempted and refused; refused after a restart too
##                       d  attempted and refused *live*; holds on restart
##          <code>     optional slug, only on s/r/d, from the closed set below
##   more `1` when the rows did not all fit in the path. The rest arrive on
##        later polls; the host rotates rather than prioritises, so every row is
##        said within a few polls.
##
## **A guid with no record is a guid this host has not answered about**, and
## that is the load-bearing distinction: there is deliberately no letter for it.
## `more=1`, a truncated path, an old host and a host that has not polled yet
## all converge on absence, and absence means unknown -- never "no", never
## "off", never "not running". The manager may only ever narrow a mod's state on
## a record it actually received.
##
## `k` is transient. The tick after a load or unload succeeds, the mod is simply
## in the state it was asked for, and the next poll reports it as `n`. Both mean
## "this mod is where you wanted it"; `k` additionally means "and this host is
## the one that just moved it". A manager deciding what is *running* must treat
## them identically -- reading `k` as a durable state and `n` as a lesser one
## would have every successful change appear to regress one poll later.
##
## Two more rules a reader has to keep:
##
##  * The query is a *report*, not a filter. The body served must be the same
##    body the bare route serves. A manager that answered a filtered set to a
##    reporting host would make the report change the thing it reports on.
##  * A bare path with no query is a host that has nothing to say -- an older
##    build, or one that has not been told a session -- and is byte-for-byte
##    what this route saw before any of this existed.
##
## ---------------------------------------------------------------------------
## Why every request is queued and nothing happens inside the emit
## ---------------------------------------------------------------------------
##
## `broadcast` is delivered synchronously. At the moment a control request
## arrives, the stack runs through the manager's own route handler -- and, for
## an unload, quite possibly through the mod being unloaded. Calling
## `FreeLibrary` there would return into unmapped memory. So `submit` only
## records the request and returns; `drain` performs it from the host's own
## loop, where the only aowlspt code on the stack is the host's.
##
## That is also why the manager's `requestUnload` answers `aoRequested` rather
## than `aoApplied` and learns the outcome from the next `result`.
##
## ---------------------------------------------------------------------------
## What is refused, and why refusing is the feature
## ---------------------------------------------------------------------------
##
## A mod is taken out only when the host can prove it left nothing behind: the
## host must have registered a teardown (`setModTeardown`), and the teardown
## must drop routes, event subscriptions, timers and detours. Without one,
## `unloadOne` refuses -- and this module reports that refusal as
## `deferred:true`, meaning "on restart", rather than unloading anyway.
##
## The `AOWLSPT_MOD_HOT_RELOADABLE` flag used to be reported in `listed` and
## required for nothing, on the reading that the flag is about *state* across a
## reload -- `state_save`/`state_load` -- while taking a mod out needs only
## `on_unload` plus the host's teardown, both of which the host guarantees.
##
## That reading was correct about the ABI and wrong about the client, and it was
## measured wrong. On the server a mod that leaves something behind costs a route
## table. On the client it costs the player's raid: two unflagged mod DLLs were
## freed during scene teardown and the client died with a native access violation
## inside a second, twice out of two runs. The teardown's guarantee covers what
## the mod registered THROUGH THE HOST -- subscriptions, queued callbacks,
## detours. It cannot cover what the mod took directly: a strong GC handle on a
## game object, a thread it started, a pointer it handed to the game.
##
## So `hotOf` in `HostOps` now gates the unload, and the CLIENT host sets it
## while the server and the simulator leave it nil. A mod that has not declared
## the flag is refused BY NAME and stays loaded; the change still holds on
## restart, because the selection is stored rather than inferred from what is
## running. Nothing is ever unloaded on the hope that it had nothing in flight.

## ---------------------------------------------------------------------------
## Why the host is passed in rather than imported
## ---------------------------------------------------------------------------
##
## Both hosts now share one loader -- `host/common/modhost.nim` -- so the
## original reason for `HostOps` (there were two loaders and importing either
## would have tied this module to one host) is gone. It stays anyway, and the
## reasons it stays are not the reason it was written:
##
##  * The wrappers are *not* the same on both sides. `load` carries the host's
##    own side, name and version; `unload` on the client also marks the mod's
##    row in the overlay as stopped. Those are host facts, and a version of
##    this module that called `modhost` directly would have to grow a way to be
##    told them anyway -- which is `HostOps` with extra steps.
##  * It keeps this module usable by a host that is not built on `modhost` --
##    the C# hosts, or the next one. The protocol is the wire, not the loader,
##    and a `modcontrol` that could only answer for `modhost.gMods` would be a
##    third implementation of the wire waiting to be written.
##
## So the host still hands over a `HostOps`: twelve small procs, each one a
## thing this module needs to know or do and nothing more, and neither host has
## to expose its mod table to get it.

import std/strutils
import aowlsptinstall/winfs
import jsonpath

type
  EmitFn* = nil proc (name, payload: string)
    ## How this module answers. Each host delivers events to its own subscriber
    ## list, so the delivery is passed in rather than reimplemented here.
    ## `nil proc` for the reason `TeardownFn` is: nimony's proc types are
    ## non-nil by default and this starts as nil.

  CountFn* = nil proc (): int
  TextOfFn* = nil proc (index: int): string
  FlagFn* = nil proc (index: int): bool
  FlagsOfFn* = nil proc (index: int): uint32
  LiveOfFn* = nil proc (index: int): bool
  LoadFn* = nil proc (path: string): bool
  UnloadFn* = nil proc (guid: string): string
    ## Empty on success; otherwise the host's own words about why not.
  IndexFn* = nil proc (guid: string): int
  LogFn* = nil proc (msg: string)

  ReleasedFn* = nil proc (): bool
    ## Whether the unload that just ran actually freed the library -- i.e.
    ## whether the DLL file can now be overwritten by a rebuild.
    ##
    ## This is a SEPARATE question from "did the unload succeed", and the two
    ## were conflated until a live run proved they differ: `completed=1`,
    ## `epoch=1`, `unloaded Bot AI` in the log, and `cannot create regular file:
    ## Device or resource busy` at the shell. Everything the host measured said
    ## the reload worked; the one thing the user wanted was impossible.

  QuiesceFn* = nil proc (): int32
    ## Whether the host is at a point where freeing a library is safe.
    ##
    ## **Three states, never two** -- `QuietYes` / `QuietBusy` / `QuietUnknown`.
    ## The third is the whole reason this is an `int32` and not a `bool`: a host
    ## that cannot see the game's main thread at all must not answer "quiet",
    ## because "I could not look" read as a pass is precisely the check that
    ## cannot fail. `QuietUnknown` refuses the unload exactly as `QuietBusy`
    ## does; only the sentence in the log differs.
    ##
    ## Measured, and why this exists: with `modSettingsRender` on, the shared
    ## sync slot was held from 0:00:02 to ~0:00:26, `takeModSet` never ran, and
    ## the unload instruction arrived ~25 s late -- landing inside scene
    ## teardown. `FreeLibrary` of two mod DLLs there killed the client with a
    ## native access violation 0.4-1.0 s later, in two runs out of two. The
    ## drain had no idea what the game was doing, and nothing in the protocol
    ## asked.

  HostOps* = object
    count*: CountFn
    guidOf*: TextOfFn
    nameOf*: TextOfFn
    versionOf*: TextOfFn
    pathOf*: TextOfFn
    liveOf*: LiveOfFn
    flagsOf*: FlagsOfFn
    indexOf*: IndexFn
    canUnload*: FlagFn
      ## Takes an index it ignores -- nimony has no zero-argument proc type in
      ## this object without a second name for it, and one shape for every
      ## predicate is worth more than the argument it discards.
    load*: LoadFn
    unload*: UnloadFn
    log*: LogFn
    hotOf*: FlagFn
      ## Whether the mod at this index declares `AOWLSPT_MOD_HOT_RELOADABLE`.
      ## Nil from a host that does not gate on it -- the server and the
      ## simulator, where a bad unload costs a route table and not a raid.
      ## Non-nil on the client, where `doUnload` refuses BY NAME for any mod
      ## that has not claimed it can come out live.
      ##
      ## The flag was declared in `abi/aowlspt_abi.h` and in both loaders from
      ## the start and, until this, was read in exactly one place: the `hot`
      ## column of `replyListed`. It decorated a list. It gated nothing, and the
      ## two DLLs that took the client down were both unflagged.
    released*: ReleasedFn
      ## Asked immediately after a successful unload; see `ReleasedFn`. Nil
      ## means the host cannot measure it, and `released` then stays 0 rather
      ## than being credited -- "I could not look" is not a release.
    quiesce*: QuiesceFn
      ## Asked immediately before each unload; see `QuiesceFn`. Nil means the
      ## host has no notion of a safe point and every unload proceeds -- which
      ## is the behaviour every host had before this, kept deliberately for the
      ## two where it is correct.

  DesiredMod* = object
    ## One row of the backend's answer to "what should be running on this
    ## side". The manager resolves, this obeys, and a host that carried enough
    ## of the registry to second-guess it would be a second resolver to keep in
    ## step -- so `verdict` and `reason` below are carried for the LOG ONLY and
    ## are never consulted by `applyDesired` when it decides what to do. That
    ## distinction is the whole of their contract: they explain the decision,
    ## they do not participate in it.
    ##
    ## They exist because a mod that is unloaded a second after it loads, with
    ## no reason given, is indistinguishable from a mod that is broken -- and
    ## the mod's own honest diagnostics ("NOT ARMED, still waiting out
    ## armDelayMs") then read as the mod's fault. It was the platform's.
    guid*: string
    enabled*: bool
    dir*: string   ## the artifact directory, relative to the host's mods root
    lib*: string   ## the library file inside it
    verdict*: string  ## the manager's slug: not-selected, disabled, wrong-side,
                      ## pipeline, missing-dependency, conflict, cycle. Empty
                      ## from a manager older than this field -- absent, not
                      ## "no verdict".
    reason*: string   ## the manager's own sentence for that verdict. Empty from
                      ## an older manager.

  PendKind = enum
    pkProbe
    pkLoad
    pkUnload
    pkList

  Pending = object
    kind: PendKind
    guid: string
    path: string
    defers: int
      ## How many drains have put this request back rather than performing it,
      ## because the host was not at a safe point. Bounded by `DeferLimit`: an
      ## unload that can never find a quiet moment must eventually be ANSWERED
      ## -- a request that is silently carried forever is indistinguishable from
      ## one that was lost, and the manager would wait on it for the life of the
      ## process.

const ControlPrefix* = "aowlspt.host.mods."
const ModHotReloadable* = 1'u32   ## AOWLSPT_MOD_HOT_RELOADABLE

const
  QuietYes* = 0'i32      ## a safe point: perform the unload
  QuietBusy* = 1'i32     ## the host is mid-something; put it back and ask again
  QuietUnknown* = 2'i32  ## the host cannot tell. REFUSED, not permitted.

const DeferLimit* = 600
  ## Roughly ten seconds of drains at the client host's tick. Past this the
  ## request is answered `deferred` with `CodeNotQuiet` and dropped, and the
  ## backend's next poll re-states the same desired set, so the attempt repeats
  ## on its own cadence rather than spinning inside one queue entry.

## The reload ledger. Counters, not a verdict: a run with zero attempts is
## INCONCLUSIVE and reads that way here, because `attempted` is 0 rather than
## because `faults` is 0. Reported through `hotReloadCounters` and rendered into
## the capabilities reply, so "it reloaded" can be falsified by a number instead
## of by the absence of a crash.
var gRlAttempted = 0
var gRlCompleted = 0
var gRlRefused = 0
var gRlDeferred = 0
var gRlReleased = 0
  ## Unloads after which the DLL file was actually writable again. This is the
  ## number that means "a code swap is possible"; `completed` only ever meant
  ## "the teardown ran". They were the same counter until a live run showed
  ## completed=1 next to a locked file, which is the §9b shape exactly: a
  ## success report for something that could not happen.
var gRlEpoch = 0
  ## Bumped once per COMPLETED unload+load pair's unload half. A mod that prints
  ## this on load prints a different number every reload; if it prints the same
  ## number twice, the library did not actually change over and "it reloaded" was
  ## indistinguishable from "nothing happened".

const RlMaxNotes* = 12
  ## Rule 4. Capped, and the cap is REPORTED when it bites -- a truncated list
  ## that does not say it is truncated is a list that reads as complete.

var gRlNotes: seq[string] = @[]
var gRlDropped = 0

proc rlNote(kind, who, why: string) =
  ## THE REASON, RECORDED NEXT TO THE COUNTER IT EXPLAINS.
  ##
  ## MEASURED 2026-09-04 (tools/hostlog.py grep, boot 6bd304e3): the run line
  ## read `hotreload: attempted=4 completed=0 released=0 refused=4` and the
  ## host log contained NO refusal reason at all -- every `gOps.log(why)`
  ## below had fired into a seam that produced nothing readable. Four refusals
  ## with no cause is indistinguishable from four refusals with the wrong
  ## cause, so the count alone was not actionable.
  ##
  ## The reason now rides the ledger itself. It cannot be separated from the
  ## counter by log ordering, by a filter, or by a nil `log` seam, because the
  ## same call that increments the counter records it.
  if gRlNotes.len >= RlMaxNotes:
    inc gRlDropped
    return
  gRlNotes.add(kind & " " & (if who.len > 0: who else: "<unnamed>") & ": " & why)

proc hotReloadNotes*(): seq[string] = gRlNotes
  ## One line per attempt that did not complete, oldest first.

proc hotReloadNotesDropped*(): int = gRlDropped

var gRlVerBefore: seq[string] = @[]
var gRlVerAfter: seq[string] = @[]

proc rlVersionBefore(guid, ver: string) =
  ## THE FALSIFIABLE HALF OF "IT RELOADED". `epoch` proves the unload half ran;
  ## it cannot prove the NEW code is what came back. The mod's own version
  ## string, read off the loader before the unload and again after the reload,
  ## can: same string twice is "nothing changed over", and that is exactly the
  ## reading a rising epoch alone would have hidden.
  if gRlVerBefore.len >= RlMaxNotes: return
  gRlVerBefore.add(guid & "=" & (if ver.len > 0: ver else: "?"))

proc rlVersionAfter(guid, ver: string) =
  if gRlVerAfter.len >= RlMaxNotes: return
  gRlVerAfter.add(guid & "=" & (if ver.len > 0: ver else: "?"))

proc hotReloadVersions*(): (seq[string], seq[string]) =
  ## (before-unload, after-reload) version strings, per guid, in attempt order.
  (gRlVerBefore, gRlVerAfter)

proc hotReloadCounters*(): (int, int, int, int, int, int) =
  ## attempted / completed / released / refused / deferred / epoch.
  ##
  ## `released` sits next to `completed` on purpose and not instead of it: the
  ## gap between the two is the diagnosis. completed>0 with released==0 is "the
  ## teardown works and something still holds the module"; both zero is "the
  ## unload never ran". Collapsing them into one number would hide the first
  ## case, which is the one that actually happened.
  result = (gRlAttempted, gRlCompleted, gRlReleased, gRlRefused, gRlDeferred,
            gRlEpoch)

proc hotReloadEpoch*(): int = gRlEpoch

var gEmit: EmitFn = nil
var gOps: HostOps = HostOps(count: nil, guidOf: nil, nameOf: nil,
                            versionOf: nil, pathOf: nil, liveOf: nil,
                            flagsOf: nil, indexOf: nil, canUnload: nil,
                            load: nil, unload: nil, log: nil,
                            hotOf: nil, quiesce: nil, released: nil)
var gHostName = ""
var gHostVersion = ""
var gSide = 0'i32
var gReady = false
var gQueue: seq[Pending] = @[]

proc controlInit*(hostName, hostVersion: string; side: int32; emit: EmitFn;
                  ops: HostOps) =
  ## Called once by the host at startup, after the mods are up. Until this
  ## runs, `submit` ignores every control request -- a half-initialised
  ## controller that answered would tell the manager the host can do things it
  ## has not been told how to do.
  gHostName = hostName
  gHostVersion = hostVersion
  gSide = side
  gEmit = emit
  gOps = ops
  gReady = true

proc note(msg: string) =
  if gOps.log != nil:
    gOps.log(msg)

proc jsonEscape(s: string): string =
  ## Enough of an escaper for the strings that go in a reply: a guid, a path
  ## (which on Windows is full of backslashes) and an error message (which is
  ## whatever the loader said, including quotes).
  result = ""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ch < ' ':
        result.add ' '
      else:
        result.add ch

proc emitReply(name, payload: string) =
  if gEmit == nil:
    return
  gEmit(name, payload)

proc isControl*(name: string): bool =
  result = name.len > ControlPrefix.len and startsWith(name, ControlPrefix)

proc submit*(name, payload: string): bool =
  ## Records a control request. Returns true when the name is one of ours, so
  ## the caller can log it as handled; the event is still delivered to any
  ## ordinary subscriber, because a second manager watching the channel is a
  ## reasonable thing to write and this is not a private wire.
  if not gReady or not isControl(name):
    return false
  let verb = name.substr(ControlPrefix.len)
  var guid = ""
  var path = ""
  discard pathGet(payload, "guid", guid)
  discard pathGet(payload, "path", path)
  # A queue that is never drained is a host with no loop, and every request
  # after this point would be a leak rather than a delay. The cap is far above
  # any real burst -- `apply` states a whole selection, which is at most the
  # registry's length -- so hitting it means the drain is gone.
  if gQueue.len >= 256:
    note "mod control: " & $gQueue.len &
         " requests are queued and nothing is draining them; dropping " & name
    return false

  case verb
  of "probe":
    gQueue.add Pending(kind: pkProbe, guid: "", path: "", defers: 0)
  of "list":
    gQueue.add Pending(kind: pkList, guid: "", path: "", defers: 0)
  of "load":
    gQueue.add Pending(kind: pkLoad, guid: guid, path: path, defers: 0)
  of "unload":
    gQueue.add Pending(kind: pkUnload, guid: guid, path: "", defers: 0)
  else:
    # A verb from a newer manager than this host. Saying so beats silence: the
    # manager's contract is that every request produces exactly one reply, and
    # a name nobody answers is indistinguishable from a host with no control at
    # all.
    note "mod control: no such request " & name
    return false
  result = true

proc replyResult(guid, action: string; ok1, deferred: bool; error: string) =
  var body = "{\"guid\":\"" & jsonEscape(guid) & "\",\"action\":\"" & action &
             "\",\"ok\":" & (if ok1: "true" else: "false") &
             ",\"deferred\":" & (if deferred: "true" else: "false") &
             ",\"error\":\"" & jsonEscape(error) & "\"}"
  emitReply(ControlPrefix & "result", body)

## ---------------------------------------------------------------------------
## The outcome ledger, and why a host that only listens is a host that lies
## ---------------------------------------------------------------------------
##
## Everything above answers the *manager*, in the manager's process. The client
## host is not in that process: it polls, it acts, and until this ledger existed
## it said nothing at all about what happened. So the manager's `live` and
## `restart` verdicts for a client-side mod were the **server's guess** -- it
## knew what it had asked for and never learned whether it worked -- and the
## overlay panel had to write `decided by: client host` / `running unknown`
## rather than state something it could not know.
##
## What is recorded here is one row per guid the backend named, carrying the
## last thing this host actually did about it. Five outcomes, and the set is
## closed on purpose: a manager that has to parse a sentence to decide what to
## draw is a manager that will draw the wrong thing the first time the sentence
## changes.
##
##   `moNoop`     nothing to do -- it was already in the requested state
##   `moOk`       attempted, and it worked
##   `moSkipped`  **not attempted**, and the host says why (`code`)
##   `moRefused`  attempted and refused, live -- and it will still be refused
##                after a restart, because the reason is not liveness
##   `moDeferred` attempted and refused *live*; the change holds on restart
##
## `moNone` is the sixth, and it is the one that carries the weight: it is never
## encoded. A guid with no row is a guid this host **has not answered about
## yet**, which is not the same as a guid it answered "no" about, and this
## project has now found the same bug twice in the places those two were allowed
## to collapse into one. So the wire has no letter for it: absence is the only
## way to say it, and a manager that treats absence as anything but "unknown"
## is wrong by construction rather than by accident.

type
  ModOutcome* = enum
    moNone      ## never encoded -- see above
    moNoop
    moOk
    moSkipped
    moRefused
    moDeferred

## The closed set of reasons. A code is a slug, not a sentence: the sentence is
## in the host's log, where it can be as long as it needs to be, and the slug is
## what the manager renders.
const
  CodeNoArtifact* = "noartifact"
    ## the registry names this mod but gives no artifact to load
  CodeNoFile* = "nofile"
    ## its library is not installed on this side -- a server-only mod
  CodeNoPath* = "nopath"
    ## a load request arrived with no path and this host cannot find one
  CodeMissing* = "missing"
    ## the loader reported success and left no live mod behind
  CodeWrongGuid* = "wrongguid"
    ## the library announces a different guid than the one requested
  CodeLoadFailed* = "loadfailed"
    ## the loader refused it; the host log carries the reason
  CodeNoTeardown* = "noteardown"
    ## this host cannot take a mod out live at all; the change holds on restart
  CodeUnloadFailed* = "unloadfailed"
    ## the unload itself failed; the host log carries the reason
  CodeNotHot* = "nothot"
    ## this mod does not declare AOWLSPT_MOD_HOT_RELOADABLE, and this side
    ## refuses to free a library that has not claimed it can come out live
  CodeNotQuiet* = "notquiet"
    ## the host never reached a safe point to free a library in; the mod stays
    ## loaded and the change holds on restart

const ReportMaxPath* = 191
  ## What one report may cost, in characters of request path, **including the
  ## route it rides on**. This is not a taste: `aowl_ov_sync_start` copies the
  ## path into a 192-byte field and the worker widens at most 191 of them, so a
  ## longer path is not a longer request, it is a silently truncated one. Every
  ## encoding decision below -- slugs rather than sentences, one letter per
  ## outcome, and a rotation instead of a full dump -- is paid for out of this.

var gRepGuid: seq[string] = @[]
var gRepWant: seq[bool] = @[]
var gRepOut: seq[ModOutcome] = @[]
var gRepCode: seq[string] = @[]
var gRepSeq = 0
var gRepCursor = 0
var gRepTruncated = false
var gRepSession = ""

proc reportSession*(id: string) =
  ## Names this host's *process*. Set once at startup by a host that polls;
  ## never set on the backend, whose manager shares its process and needs none
  ## of this.
  ##
  ## It is on the wire because every outcome below is scoped to one run of one
  ## game. A manager holding "aowl.foo refused" from the session before last and
  ## drawing it against the client running now would be reporting a fact about a
  ## process that no longer exists -- which is the same class of lie as guessing,
  ## with the added charm of looking authoritative. A changed `hs` means every
  ## outcome the manager holds for this host is stale and drops back to unknown.
  gRepSession = id

var gRepBotNav = ""

proc reportBotNav*(census: string) =
  ## Publish the host's live bot registry so it goes out on the next poll.
  ##
  ## It rides `reportPath`'s query string for the same reason the mod outcomes
  ## do: the client host has exactly one route to the backend, that route is
  ## already being walked every `modSyncMs`, and riding it costs nothing that is
  ## not already being spent -- the same request, a longer path. A second channel
  ## would need an HTTP client, a socket and a thread inside a DLL injected into
  ## a running game.
  ##
  ## The census is a STATE, not an event, so repeating it is free and losing one
  ## costs nothing: the next poll carries the current truth. That is why there is
  ## no sequence number and no ack here, unlike the mod outcome rows.
  ##
  ## Format (one record per live bot, `!`-separated), built in `botnav.nim`:
  ##     id,role,difficulty,alive,x,y,z,lastNavStatus
  gRepBotNav = census

proc reportSeq*(): int = gRepSeq
  ## Bumped whenever any row changes and never otherwise, so a caller can tell
  ## "there is something new to say" from "say the same thing again".

proc reportPending*(): bool = gRepTruncated
  ## True when the last path built could not carry every row. The rest are not
  ## lost -- the next build starts where this one stopped -- but the caller has
  ## to build again for them to be said.

proc recordOutcome(guid: string; want: bool; outcome: ModOutcome;
                   code: string) =
  ## One row per guid, overwritten. The sequence moves only on a real change:
  ## `applyDesired` records `moNoop` for every settled mod on every poll, and a
  ## sequence that counted those would report news twenty times a minute forever.
  if guid.len == 0 or outcome == moNone:
    return
  for i in 0 ..< gRepGuid.len:
    if gRepGuid[i] == guid:
      if gRepWant[i] == want and gRepOut[i] == outcome and gRepCode[i] == code:
        return
      gRepWant[i] = want
      gRepOut[i] = outcome
      gRepCode[i] = code
      inc gRepSeq
      return
  gRepGuid.add guid
  gRepWant.add want
  gRepOut.add outcome
  gRepCode.add code
  inc gRepSeq

proc forgetOutcomes(keep: seq[string]) =
  ## Drops rows for guids the backend has stopped naming. A row that outlives
  ## the mod it is about is the stale-fact problem again, one scope down: the
  ## manager would keep drawing a verdict for something its own registry no
  ## longer lists.
  var i = 0
  while i < gRepGuid.len:
    var wanted = false
    for g in keep:
      if g == gRepGuid[i]:
        wanted = true
    if wanted:
      inc i
      continue
    gRepGuid.delete(i)
    gRepWant.delete(i)
    gRepOut.delete(i)
    gRepCode.delete(i)
    inc gRepSeq
    if gRepCursor > i:
      dec gRepCursor
  if gRepCursor > gRepGuid.len:
    gRepCursor = 0

proc answer(guid, action: string; ok1, deferred: bool; error: string;
            outcome: ModOutcome; code: string) =
  ## Both halves of a reply: the event the manager subscribes to, and the row
  ## the poll will carry. They are written together so that a future branch
  ## cannot answer one and forget the other -- which would present exactly as
  ## "the server-side switch works and the client-side one does nothing", the
  ## bug this whole ledger exists to close.
  replyResult(guid, action, ok1, deferred, error)
  recordOutcome(guid, action == "load", outcome, code)

proc outcomeLetter(o: ModOutcome): char =
  result = 'u'
  case o
  of moNone: result = 'u'
  of moNoop: result = 'n'
  of moOk: result = 'k'
  of moSkipped: result = 's'
  of moRefused: result = 'r'
  of moDeferred: result = 'd'

proc urlSafe(s: string): string =
  ## Guids and slugs only, and both are already `[a-z0-9.-]` by every convention
  ## in the registry. Anything else is dropped rather than escaped: a percent
  ## escape would cost three characters out of a budget of 191 to carry a
  ## character that cannot legitimately be there, and dropping it cannot forge a
  ## *different* valid guid -- it can only produce one the manager does not know,
  ## which reads as unknown, which is the safe answer.
  result = ""
  for ch in s:
    if (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
       (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '_':
      result.add ch

proc reportRows(base: string; budget: int): string =
  ## `base`, with everything this host has to say about the mods the backend
  ## named appended as a query string -- and never longer than `budget`.
  ##
  ## The report rides on the poll the client host already makes, rather than on
  ## a channel of its own, and that is the whole design. A second channel would
  ## need an HTTP client, a socket and a thread inside a DLL injected into a
  ## running game, all three of which exist here exactly once, in the overlay,
  ## for the panel. It would also need the far end to be reachable at a moment
  ## the host chose, which is precisely the property a poll declines to depend
  ## on. Riding the poll costs nothing that is not already being spent: the same
  ## request, a longer path.
  ##
  ## `base` alone is returned when there is nothing to say -- no session, no
  ## rows -- so a host that has not started reporting is byte-for-byte the host
  ## that came before this, and an old manager reading the bare route sees
  ## exactly what it saw.
  ##
  ## When the rows do not all fit, the ones that did are sent, `more=1` says so,
  ## and the next call starts where this one stopped. Rotation rather than
  ## priority: every row is said within a few polls, no row can be starved by a
  ## noisier neighbour, and the manager needs no ack for that to be true because
  ## each row is a *state* and repeating it is free.
  result = base
  gRepTruncated = false
  if gRepSession.len == 0 or gRepGuid.len == 0:
    return
  let head = base & "?hs=" & urlSafe(gRepSession) & "&sq=" & $gRepSeq & "&r="
  # The smallest possible record is `g~+n`, and `&more=1` has to be affordable
  # for the truncated case. Below that there is no honest report to make, so the
  # bare route goes out and the manager stays at unknown -- which it is.
  if head.len + 4 + 7 > budget:
    return
  var body = ""
  var emitted = 0
  var i = 0
  var stoppedAt = -1
  while i < gRepGuid.len:
    let k = (gRepCursor + i) mod gRepGuid.len
    inc i
    var rec = urlSafe(gRepGuid[k])
    if rec.len == 0:
      continue
    rec.add '~'
    rec.add (if gRepWant[k]: '+' else: '-')
    rec.add outcomeLetter(gRepOut[k])
    if gRepCode[k].len > 0:
      rec.add '~'
      rec.add urlSafe(gRepCode[k])
    # A record that cannot fit into an empty report will never fit into any
    # report, so it is skipped rather than allowed to wedge the rotation behind
    # it. It stays unknown to the manager, which is the truth about it.
    if head.len + rec.len + 7 > budget:
      gRepTruncated = true
      continue
    let sep = if body.len > 0: 1 else: 0
    if head.len + body.len + sep + rec.len + 7 > budget:
      stoppedAt = k
      break
    if body.len > 0:
      body.add '!'
    body.add rec
    inc emitted
  if stoppedAt >= 0:
    gRepTruncated = true
    gRepCursor = stoppedAt
  else:
    gRepCursor = 0
  if emitted == 0:
    return
  result = head & body
  if gRepTruncated:
    result = result & "&more=1"

proc reportPath*(base: string; budget: int = ReportMaxPath): string =
  ## The mod-outcome report (`reportRows`, unchanged), plus the live bot registry
  ## when there is one.
  ##
  ## The two are appended independently and neither can starve the other: the
  ## census is added only out of whatever budget the rows left, and it is dropped
  ## whole rather than truncated, because half a coordinate list is worse than
  ## none. A host with no botnav registry produces a path byte-for-byte identical
  ## to the one the host before this produced, so an old manager reading the
  ## route sees exactly what it saw.
  result = reportRows(base, budget)
  if gRepBotNav.len == 0:
    return
  # NOT `urlSafe`: that one drops everything outside `[A-Za-z0-9._-]`, which
  # would silently eat the `,` and `!` separators and hand the manager a census
  # that parses into nonsense. The census alphabet is fixed and already
  # query-string-legal, so the encoder here keeps exactly that and drops the
  # rest -- the same "drop rather than escape" rule, applied to a wider set.
  var enc = ""
  for ch in gRepBotNav:
    if (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
       (ch >= '0' and ch <= '9') or ch == '.' or ch == '-' or ch == '_' or
       ch == ',' or ch == '!' or ch == '+':
      enc.add ch
  if enc.len == 0:
    return
  let sep = (if result.contains('?'): "&" else: "?")
  if result.len + sep.len + 3 + enc.len > budget:
    return
  result = result & sep & "bn=" & enc

proc replyCapabilities() =
  # `reloadNeedsRestart` is answered from what the host can actually do rather
  # than from a constant: a host with no teardown registered can load a mod but
  # not take one out, and claiming otherwise would have the manager offer a
  # switch that always reports "deferred".
  let canUnload = gOps.canUnload != nil and gOps.canUnload(0)
  var body = "{\"host\":\"" & jsonEscape(gHostName) & "\",\"version\":\"" &
             jsonEscape(gHostVersion) & "\",\"control\":true,\"load\":true," &
             "\"unload\":" & (if canUnload: "true" else: "false") &
             ",\"reloadNeedsRestart\":" &
             (if canUnload: "false" else: "true") & "}"
  emitReply(ControlPrefix & "capabilities", body)

proc listedRowFor(guid: string): int =
  ## Which of a guid's rows to report, or -1 when this is not the one.
  ##
  ## The loader keeps dead slots -- a context pointer is an index, so a row is
  ## never removed -- and a mod that has been switched off and on again
  ## therefore owns one row per toggle, all but the last of them a corpse with
  ## the same guid. Reporting every one of them made this reply grow by a row
  ## per toggle for the life of the process, which is a table growing without
  ## bound in a message the manager parses; at a few dozen toggles it is already
  ## larger than the buffers on either side of it.
  ##
  ## So one row per guid: the live one if there is one, otherwise the last,
  ## which is the most recent thing that mod said about itself. The manager's
  ## contract is unaffected -- it draws one row per mod and asks for a guid, not
  ## for an index -- and "this mod is here and is not running" is still exactly
  ## what a guid with no live row answers.
  result = -1
  var lastDead = -1
  for i in 0 ..< gOps.count():
    if gOps.guidOf(i) != guid:
      continue
    if gOps.liveOf(i):
      return i
    lastDead = i
  result = lastDead

proc replyListed() =
  var body = "{\"mods\":["
  var first = true
  for i in 0 ..< gOps.count():
    # One row per guid. See `listedRowFor`: dead slots are kept and reported,
    # but a guid with twenty of them is twenty rows saying the same thing.
    if listedRowFor(gOps.guidOf(i)) != i:
      continue
    if not first:
      body.add ","
    first = false
    let hot = (gOps.flagsOf(i) and ModHotReloadable) != 0'u32
    body.add "{\"guid\":\"" & jsonEscape(gOps.guidOf(i)) &
             "\",\"name\":\"" & jsonEscape(gOps.nameOf(i)) &
             "\",\"version\":\"" & jsonEscape(gOps.versionOf(i)) &
             "\",\"path\":\"" & jsonEscape(gOps.pathOf(i)) &
             "\",\"live\":" & (if gOps.liveOf(i): "true" else: "false") &
             ",\"hotReloadable\":" & (if hot: "true" else: "false") & "}"
  body.add "]}"
  emitReply(ControlPrefix & "listed", body)

proc doLoad(p: Pending) =
  # Idempotent by contract: `/aowlspt/mods/apply` states the whole desired set
  # rather than a diff, so a guid that is already up is an ordinary case and
  # must answer ok rather than loading a second copy.
  if p.guid.len > 0 and gOps.indexOf(p.guid) >= 0:
    answer(p.guid, "load", true, false, "", moNoop, "")
    return
  if p.path.len == 0:
    answer(p.guid, "load", false, false,
           "no path: this host cannot find a mod by guid alone",
           moRefused, CodeNoPath)
    return
  if not fileExists(p.path):
    answer(p.guid, "load", false, false, "no such file: " & p.path,
           moSkipped, CodeNoFile)
    return
  if gOps.load(p.path):
    # The guid is read back off what actually loaded rather than echoed: a
    # request naming one guid and a library exporting another is a mistake the
    # manager has to see, and echoing the request would hide it.
    #
    # Found by **path**, not by taking the last slot. The loader keeps dead
    # slots rather than compacting -- every mod's context pointer is its index
    # -- so "the last slot" is only ever the newest one by accident, and a
    # reader that assumed it would report a neighbour's guid the first time a
    # slot was reused. The failure would look like a mislabelled mod.
    var idx = -1
    for i in 0 ..< gOps.count():
      if gOps.liveOf(i) and gOps.pathOf(i) == p.path:
        idx = i
    if idx < 0:
      answer(p.guid, "load", false, false,
             "the host reported success but has no live mod from " & p.path,
             moRefused, CodeMissing)
      return
    let got = gOps.guidOf(idx)
    if p.guid.len > 0 and got != p.guid:
      # And take it back out again. Reporting the mismatch while leaving the
      # library loaded is the worst of both: the manager believes the mod it
      # asked for is not running, the host is running one it never asked for,
      # and every later `apply` tries to load it again on top of itself.
      let undo = gOps.unload(got)
      var why = "that library exports " & got & ", not " & p.guid
      if undo.len > 0:
        why = why & "; and it could not be taken back out again (" & undo &
              "), so it is running and this host cannot stop it"
      answer(p.guid, "load", false, false, why, moRefused, CodeWrongGuid)
      return
    # THE VERDICT READS THE MOD'S NEW VERSION STRING. Recorded only for a guid
    # this session actually unloaded, so an ordinary first load does not
    # manufacture a reload that never happened.
    for b in gRlVerBefore:
      if b.len > got.len and b[0 ..< got.len] == got and b[got.len] == '=':
        rlVersionAfter(got,
                       (if gOps.versionOf != nil: gOps.versionOf(idx) else: ""))
        break
    answer(got, "load", true, false, "", moOk, "")
  else:
    # `loadMod` refuses for reasons it has already written to the log with the
    # detail; the manager gets the short form and the log has the rest.
    answer(p.guid, "load", false, false,
           "the host refused to load " & p.path & "; see the host log",
           moRefused, CodeLoadFailed)

proc doUnload(p: Pending): bool =
  ## `false` means "not performed, put it back" -- the host was not at a safe
  ## point. Every other outcome, including every refusal, is `true` and has been
  ## ANSWERED. A path that returns `false` without also being under the
  ## `DeferLimit` would be a request that is never answered at all.
  result = true
  if p.guid.len == 0:
    replyResult("", "unload", false, false, "no guid")
    return
  let idx = gOps.indexOf(p.guid)
  if idx < 0:
    # Already out, which is the same end state the caller asked for.
    answer(p.guid, "unload", true, false, "", moNoop, "")
    return

  # THE CONTRACT, asked first and by name. A mod that has not declared
  # AOWLSPT_MOD_HOT_RELOADABLE is refused here and STAYS LOADED -- it is never
  # unloaded on the hope that it had nothing in flight. The refusal names the
  # mod, because "some mod would not unload" is not something anyone can act on.
  if gOps.hotOf != nil and not gOps.hotOf(idx):
    inc gRlAttempted
    inc gRlRefused
    let nm = (if gOps.nameOf != nil: gOps.nameOf(idx) else: p.guid)
    rlNote("REFUSED", nm, "does not declare AOWLSPT_MOD_HOT_RELOADABLE (" &
           CodeNotHot & "); it stays loaded and the change holds on restart")
    let why = nm & " does not declare AOWLSPT_MOD_HOT_RELOADABLE, so this " &
              "host will not free its library while the game is running; it " &
              "stays loaded and the change holds on restart"
    if gOps.log != nil: gOps.log(why)
    answer(p.guid, "unload", false, true, why, moDeferred, CodeNotHot)
    return

  # THE SAFE POINT. Three states and only one of them proceeds.
  if gOps.quiesce != nil:
    let q = gOps.quiesce()
    if q != QuietYes:
      if p.defers < DeferLimit:
        return false
      inc gRlAttempted
      inc gRlDeferred
      let nm = (if gOps.nameOf != nil: gOps.nameOf(idx) else: p.guid)
      let what = (if q == QuietUnknown:
                    "this host cannot see whether the game is at a safe point"
                  else: "the game was never at a safe point")
      let why = nm & " was not unloaded: " & what & " in " & $DeferLimit &
                " drains, so its library was not freed. It stays loaded and " &
                "the change holds on restart."
      if gOps.log != nil: gOps.log(why)
      rlNote("DEFERRED", nm, what & " in " & $DeferLimit & " drains (" &
             CodeNotQuiet & ")")
      answer(p.guid, "unload", false, true, why, moDeferred, CodeNotQuiet)
      return

  inc gRlAttempted
  # The version BEFORE the swap, read off the loader while the old library is
  # still the live one. There is no second chance: after `unload` the slot is
  # gone and `versionOf` has nothing to answer with.
  rlVersionBefore(p.guid,
                  (if gOps.versionOf != nil: gOps.versionOf(idx) else: ""))
  # Asked *before* the attempt, so the reason can be told apart afterwards. A
  # host with no teardown refuses every unload for one reason and a host with
  # one refuses a particular unload for another; both answer `deferred`, and a
  # manager that cannot distinguish them cannot tell "this build cannot do live
  # unloads" from "this mod would not come out".
  let live = gOps.canUnload != nil and gOps.canUnload(0)
  let err = gOps.unload(p.guid)
  if err.len == 0:
    inc gRlCompleted
    inc gRlEpoch
    # Credited ONLY on a measured release. A nil `released` seam means the host
    # cannot tell, and cannot-tell is not a pass.
    if gOps.released != nil and gOps.released():
      inc gRlReleased
    else:
      rlNote("NOT-RELEASED", p.guid,
             "the teardown ran and the DLL file is still locked, so a rebuilt " &
             "library cannot replace it")
      if gOps.log != nil:
        gOps.log("hotreload: " & p.guid & " unloaded but its library was NOT " &
                 "released -- the teardown ran and the file is still locked, " &
                 "so a rebuilt DLL cannot replace it. See the NOT RELEASED " &
                 "line above for the write-probe error.")
    answer(p.guid, "unload", true, false, "", moOk, "")
  else:
    # `deferred`, not `refused`: everything that stops an unload here is
    # "this host cannot do it live", and the change still holds on restart
    # because the selection is stored rather than inferred from what is
    # running.
    rlNote("FAILED", p.guid, err & " (" &
           (if live: CodeUnloadFailed else: CodeNoTeardown) & ")")
    answer(p.guid, "unload", false, true, err, moDeferred,
           (if live: CodeUnloadFailed else: CodeNoTeardown))

proc drain*() =
  ## Called from the host's own loop, once a tick. Everything queued is
  ## performed and answered here and nowhere else.
  ##
  ## The queue is taken wholesale before anything runs: performing a request
  ## loads or unloads a mod, which can emit, which can queue another request,
  ## and appending to a sequence being walked by index is how that becomes a
  ## request that runs twice or never.
  if gQueue.len == 0:
    return
  var work = gQueue
  gQueue = @[]
  var again: seq[Pending] = @[]
  for p in work:
    case p.kind
    of pkProbe: replyCapabilities()
    of pkList: replyListed()
    of pkLoad: doLoad(p)
    of pkUnload:
      if not doUnload(p):
        # Put back with the counter advanced, so the deferral is BOUNDED. The
        # copy is appended to a separate sequence and merged after the walk, for
        # the same reason the queue was taken wholesale: appending to what is
        # being iterated is how a request runs twice or never.
        var q = p
        q.defers = p.defers + 1
        again.add q
  for q in again:
    gQueue.add q

## ---------------------------------------------------------------------------
## Making the live set match a set the backend states
## ---------------------------------------------------------------------------
##
## Everything above is *request*-shaped: the manager, running in the same
## process, emits one load or one unload and gets one answer. That is the whole
## story on the server, where the manager and the host share an event channel.
##
## The client host is a different process. Events do not cross processes, so
## nothing there ever drives the protocol above, and a player toggling a
## client-side mod in the overlay changed a stored selection and nothing else
## until the game restarted.
##
## What crosses a process boundary is HTTP, and the backend already serves the
## manager's decisions. So the client host asks -- on a slow timer, and never
## the other way round -- and hands the answer to `applyDesired`, which turns
## "here is the whole desired set" into the same `pkLoad`/`pkUnload` entries the
## manager's own requests become. It reuses the queue for the reason the queue
## exists: the answer arrives on a worker thread, and a `FreeLibrary` there
## would be a `FreeLibrary` on a thread that has no business owning the mod
## table. Everything below only *queues*; `drain` still does the deed, still
## from the host's own loop.
##
## Poll rather than push, and the asymmetry is deliberate. A backend that is
## down, starting, restarting or answering something else entirely must leave
## the host running exactly what it is running -- so the failure mode of every
## step here is "no action", never "unload it to be safe". Unloading a mod
## because a server hiccuped is the worst outcome available.
##
## Three things this does **not** cover, which is cheaper to say than to find
## out:
##
##  * A mod the backend does not name is left alone, and said so once. That
##    includes a dll dropped into `mods/` by hand: the manager can only speak
##    for what its registry lists.
##  * A load or unload the host refuses is not retried until the backend's
##    answer for that mod changes. One failed attempt per change, not one per
##    poll, because the alternative is the same log line every few seconds
##    forever.
##  * Order is not honoured. The manager resolves a load order and this applies
##    a set, so a mod that must come up after another comes up in whatever order
##    the rows are in. It has not mattered because the client-side mods do not
##    depend on each other; when it does, the fix is to sort by the order the
##    backend already computes, not to invent one here.

const DesiredSchema* = "aowlspt.clientset/1"

## Guids this host has already acted on, and what it was asked for. Without
## this a load the host refuses is retried on every poll, which is the same log
## line every few seconds for something that is not going to start working.
var gActedGuid: seq[string] = @[]
var gActedWant: seq[bool] = @[]
## Guids that are running here and that the backend has never mentioned,
## reported once each and then left alone.
var gStrangers: seq[string] = @[]

proc jsonBool(doc, key: string; into: var bool): bool =
  var raw = ""
  if not pathGet(doc, key, raw):
    return false
  let v = strip(raw)
  if v == "true":
    into = true
    return true
  if v == "false":
    into = false
    return true
  result = false

proc parseInRaid*(doc: string; into: var bool): bool =
  ## Reads the backend's `inRaid` flag out of a client-set poll response. The
  ## manager folds it into the same body `parseDesired` validates, so a caller
  ## reads it only after `parseDesired` has accepted the document. Returns false
  ## (leaving `into` untouched) when the field is absent — an older manager, or a
  ## body that never carried it — so the caller keeps its last known state rather
  ## than guessing.
  jsonBool(doc, "inRaid", into)

const MenuModeTextMax* = 48
  ## The longest string the host will carry to the menu's corner label. The
  ## label is one short line in a corner; a value longer than this is a mistake
  ## or a mischief, and either way the answer is to refuse it rather than to
  ## push it at a UI that has to lay it out.

proc parseMenuModeText*(doc: string; into: var string): bool =
  ## Reads the backend's `menuModeText` out of a client-set poll response — the
  ## string the main menu's bottom-right corner label should show instead of the
  ## stock "PVE ZONE".
  ##
  ## It rides the same body `parseDesired` validates and `parseInRaid` reads,
  ## for the same reason: the client host has exactly one route to the backend
  ## and adding a second would add a second thing that can be down. A caller
  ## reads it only after `parseDesired` has accepted the document.
  ##
  ## Returns false, leaving `into` untouched, for every unhappy case — the field
  ## absent (an older manager), empty, over-long, or carrying a character that
  ## has no business in a corner label. That is deliberate and it is the whole
  ## safety story on this side: the only thing that can move the label is a
  ## complete document carrying a short, plain, printable string.
  ##
  ## PRINTABLE ASCII ONLY. Not squeamishness: the host renders this by allocating
  ## a managed `System.String` from UTF-8 and the reader that checks it back is
  ## ASCII-only, so anything else would be written and then read back as a
  ## mismatch and rewritten on the next frame — a per-frame allocation loop,
  ## which is the exact shape of a crash this host has already had once.
  var raw = ""
  if not pathGet(doc, "menuModeText", raw):
    return false
  let v = strip(raw)
  if v.len == 0 or v.len > MenuModeTextMax:
    return false
  for ch in v:
    if ord(ch) < 0x20 or ord(ch) > 0x7E:
      return false
  into = v
  result = true

const BotNavMax* = 512
  ## The longest `botNav` command string the host will carry. Sixteen commands
  ## of the documented grammar fit comfortably; anything longer is a mistake or a
  ## mischief, and either way the answer is to refuse it rather than to hand a
  ## long unvalidated string to a parser that runs beside a live game.

proc parseBotNav*(doc: string; into: var string): bool =
  ## Reads the backend's `botNav` out of a client-set poll response -- the bot
  ## navigation command set the host should apply on its next bot tick.
  ##
  ## It rides the same body `parseDesired` validates and `parseInRaid` and
  ## `parseMenuModeText` read, for the same reason: the client host has exactly
  ## one route to the backend and adding a second would add a second thing that
  ## can be down. A caller reads it only after `parseDesired` has accepted the
  ## document.
  ##
  ## The value is a flat scalar, not a JSON array, precisely so that ALL of its
  ## gating happens right here in one place -- length and charset -- before any
  ## of it reaches the command parser, let alone a game pointer. The grammar is
  ## documented on `bnParseCommands` in `host/Aowlspt.Host.Il2Cpp/botnav.nim`:
  ##
  ##     "7|213.5|1.4|-58.2|2.0|1|30000;all|stop"
  ##
  ## Returns false, leaving `into` untouched, for every unhappy case -- the field
  ## absent (an older manager), over-long, or carrying a character with no
  ## business in a coordinate list. An EMPTY value is accepted and means "no
  ## commands", which is how a caller clears the set.
  ##
  ## Note the deliberate asymmetry with `parseMenuModeText`, which refuses empty:
  ## a corner label has a stock value to fall back to, whereas "no commands" is a
  ## real and necessary state for a command channel.
  var raw = ""
  if not pathGet(doc, "botNav", raw):
    return false
  let v = strip(raw)
  if v.len > BotNavMax:
    return false
  for ch in v:
    let o = ord(ch)
    let okCh = (o >= ord('0') and o <= ord('9')) or
               (o >= ord('a') and o <= ord('z')) or
               ch == '|' or ch == ';' or ch == ',' or ch == '.' or
               ch == '-' or ch == '+' or ch == ' '
    if not okCh:
      return false
  into = v
  result = true

proc jsonInt(doc, key: string; into: var int): bool =
  var raw = ""
  if not pathGet(doc, key, raw):
    return false
  let v = strip(raw)
  if v.len == 0:
    return false
  var n = 0
  for ch in v:
    if ch < '0' or ch > '9':
      return false
    n = n * 10 + (ord(ch) - ord('0'))
  into = n
  result = true

proc parseDesired*(doc: string; into: var seq[DesiredMod];
                   error: var string): bool =
  ## Reads the backend's desired set, and refuses everything it is not certain
  ## about.
  ##
  ## Four checks, and each is here because of a way the body can be wrong
  ## without looking wrong:
  ##
  ##  * `schema` -- a different route, an error page, or a newer manager. The
  ##    name carries a version so a change of shape is a refusal rather than a
  ##    misreading.
  ##  * `ok` -- the manager's own "this answer is usable". A registry it could
  ##    not read still produces a body.
  ##  * `count` against the rows actually read -- the check that catches a body
  ##    cut in half by a buffer, which is otherwise perfectly parseable and says
  ##    half the mods should be off.
  ##  * `complete`, which the manager writes *last*. Belt and braces with
  ##    `count`, and free: a truncated body loses its final key before it loses
  ##    anything else.
  ##
  ## A body that fails any of them yields no rows and a sentence, and the caller
  ## does nothing at all.
  into = @[]
  error = ""
  if doc.len == 0:
    error = "empty body"
    return false
  var schema = ""
  if not pathGet(doc, "schema", schema):
    error = "no schema key; this is not the mod-set route"
    return false
  if schema != DesiredSchema:
    error = "schema is " & schema & ", not " & DesiredSchema
    return false
  var ok1 = false
  if not jsonBool(doc, "ok", ok1) or not ok1:
    var why = ""
    discard pathGet(doc, "error", why)
    error = "the backend says its answer is not usable" &
            (if why.len > 0: ": " & why else: "")
    return false
  var complete = false
  if not jsonBool(doc, "complete", complete) or not complete:
    error = "the body has no terminating complete key, so it was cut short"
    return false
  var count = -1
  if not jsonInt(doc, "count", count):
    error = "no count"
    return false
  var rows: seq[string] = @[]
  if not pathItems(doc, "mods", rows):
    error = "no mods array"
    return false
  if rows.len != count:
    error = "the body says " & $count & " mods and carries " & $rows.len
    return false
  var built: seq[DesiredMod] = @[]
  for row in rows:
    var guid = ""
    if not pathGet(row, "guid", guid) or guid.len == 0:
      error = "a row with no guid"
      return false
    var on1 = false
    if not jsonBool(row, "enabled", on1):
      error = guid & ": no enabled flag"
      return false
    var dir = ""
    var lib = ""
    discard pathGet(row, "dir", dir)
    discard pathGet(row, "lib", lib)
    # Optional, and `discard`ed on purpose: a manager that predates these two
    # keys is not a malformed body. Absence leaves them empty, and the log line
    # below says "the backend did not say" rather than inventing a reason.
    var verdict = ""
    var reason = ""
    discard pathGet(row, "verdict", verdict)
    discard pathGet(row, "reason", reason)
    built.add DesiredMod(guid: guid, enabled: on1, dir: dir, lib: lib,
                         verdict: verdict, reason: reason)
  into = built
  result = true

proc actedIndex(guid: string): int =
  ## The slot recording what this host last asked for about `guid`, or -1.
  ## An empty name is a slot that was forgotten and is free to reuse, and a
  ## guid is never empty, so the comparison needs no special case.
  result = -1
  for i in 0 ..< gActedGuid.len:
    if gActedGuid[i] == guid:
      return i

proc rememberAct(guid: string; want: bool) =
  let at = actedIndex(guid)
  if at >= 0:
    gActedWant[at] = want
    return
  # A slot emptied by `forgetAct` is reused rather than left behind. Without
  # this the table grows by one entry per toggle for the life of the process,
  # which is a small leak with no bound on it.
  for i in 0 ..< gActedGuid.len:
    if gActedGuid[i].len == 0:
      gActedGuid[i] = guid
      gActedWant[i] = want
      return
  gActedGuid.add guid
  gActedWant.add want

proc forgetAct(guid: string) =
  let at = actedIndex(guid)
  if at >= 0:
    gActedGuid[at] = ""

proc alreadyTried(guid: string; want: bool): bool =
  let at = actedIndex(guid)
  result = at >= 0 and gActedWant[at] == want

proc knownStranger(guid: string): bool =
  for g in gStrangers:
    if g == guid:
      return true
  result = false

proc enableAdvice(guid: string): string =
  ## The one action that actually changes the answer, named exactly.
  ##
  ## Not "edit the selection file": the mod manager OWNS
  ## `mods\aowlspt-selection.json` and rewrites it, so a hand-edit there is
  ## reverted and looks like the advice was wrong. The override route is the
  ## supported path and it is the one that survives.
  result = "TO ENABLE IT, ask the backend once: " &
           "GET /aowlspt/mods/enable/" & guid &
           " -- or add it to a list in registry/mods.json. Do NOT hand-edit " &
           "mods\\aowlspt-selection.json; aowl.manager owns that file and " &
           "overwrites it."

proc unloadExplanation(d: DesiredMod): string =
  ## Why the backend says this mod should not be running, in words.
  ##
  ## Never a guess. An empty verdict is reported as "the backend did not say",
  ## because a confidently wrong diagnostic is worse than none -- and a slug
  ## this host has not been taught is printed verbatim rather than mapped to
  ## the nearest one it knows.
  if d.verdict.len == 0:
    return "the backend named no verdict (a manager older than this host). " &
           "Ask it directly: GET /aowlspt/mods/describe/" & d.guid
  var what = "verdict \"" & d.verdict & "\", which this host does not have " &
             "wording for"
  if d.verdict == "not-selected":
    what = "NOT SELECTED -- it is in the registry, but no active mod list " &
           "mentions it and there is no override for it, so nothing ever " &
           "asked for it. This is the DEFAULT state of every newly added mod " &
           "and it is not a fault in the mod. " & enableAdvice(d.guid)
  elif d.verdict == "disabled":
    what = "DISABLED -- a list or the user switched it off deliberately. " &
           enableAdvice(d.guid)
  elif d.verdict == "wrong-side":
    what = "WRONG SIDE -- its registry entry does not declare the client " &
           "side, so add \"client\" to its sides in registry/mods.json"
  elif d.verdict == "pipeline":
    what = "PIPELINE -- its registry pipeline range excludes this host version"
  elif d.verdict == "missing-dependency":
    what = "MISSING DEPENDENCY -- something it requires is absent, switched " &
           "off, or the wrong version"
  elif d.verdict == "conflict":
    what = "CONFLICT -- it conflicts with another enabled mod"
  elif d.verdict == "cycle":
    what = "CYCLE -- it is part of a requires cycle"
  result = what &
           (if d.reason.len > 0: " [the manager's own words: " & d.reason & "]"
            else: "")

proc applyDesired*(want: seq[DesiredMod]; modsRoot: string) =
  ## Queue whatever it takes for the live set to become `want`.
  ##
  ## Nothing here loads or unloads anything: it appends to the same queue the
  ## manager's own requests land in, and `drain` -- on the host's own loop --
  ## performs them. That is not tidiness. This is called from the tick that
  ## noticed a new answer, and the answer was fetched on a worker thread; the
  ## queue is what keeps the actual `FreeLibrary` on the one thread that owns
  ## the mod table.
  if not gReady:
    return

  for d in want:
    let live = gOps.indexOf(d.guid) >= 0
    if live == d.enabled:
      # Already right. Forgetting any earlier attempt here is what makes "one
      # attempt per change" work in both directions: a mod switched off, back
      # on and off again gets a fresh attempt each time.
      forgetAct(d.guid)
      # And said so. This is the row that retires "running unknown": a mod that
      # needed nothing doing is the commonest state by far, and a host that only
      # reported the mods it *moved* would leave the manager guessing about
      # every settled one -- which is the guess this whole path exists to stop.
      recordOutcome(d.guid, d.enabled, moNoop, "")
      continue
    if alreadyTried(d.guid, d.enabled):
      # One attempt per change, and the outcome of that attempt still stands --
      # so the row is left exactly as the attempt wrote it. Overwriting it here
      # with anything, including "unknown", would have the manager watch a
      # refusal flicker back to a guess on the next poll.
      continue
    if d.enabled:
      if d.dir.len == 0 or d.lib.len == 0:
        note "the backend wants " & d.guid & " loaded, but the registry gives " &
             "no artifact for it, so there is no library to load"
        rememberAct(d.guid, d.enabled)
        recordOutcome(d.guid, d.enabled, moSkipped, CodeNoArtifact)
        continue
      let path = joinPath(joinPath(modsRoot, d.dir), d.lib)
      if not fileExists(path):
        note "the backend wants " & d.guid & " loaded and there is no " &
             path & " on this side; it is installed on the server only"
        rememberAct(d.guid, d.enabled)
        recordOutcome(d.guid, d.enabled, moSkipped, CodeNoFile)
        continue
      note "the backend wants " & d.guid & " loaded; queueing " & path
      gQueue.add Pending(kind: pkLoad, guid: d.guid, path: path, defers: 0)
    else:
      # LOUD, and it names the reason and the fix. A mod that loads and is
      # taken back out a second later, with nothing said but "the backend
      # wants it unloaded", is indistinguishable from a mod that is broken --
      # and the mod's own honest "NOT ARMED, still waiting out armDelayMs"
      # then reads as the mod's fault. It is not: it never got the chance.
      note "MOD REJECTED BY THE PLATFORM, not broken: " & d.guid &
           " is being UNLOADED because the backend's mod set says " &
           unloadExplanation(d) &
           ". Anything " & d.guid & " says after this about not being armed " &
           "is a CONSEQUENCE of this unload, not a cause."
      gQueue.add Pending(kind: pkUnload, guid: d.guid, path: "", defers: 0)
    rememberAct(d.guid, d.enabled)

  # Rows for guids the backend has stopped naming go now. Everything above has
  # had its say about this set, so what is left over is about a previous one.
  var named: seq[string] = @[]
  for d in want:
    named.add d.guid
  forgetOutcomes(named)

  # Anything running that the backend did not mention. Named once and then left
  # entirely alone -- a hand-dropped dll is somebody's deliberate act, the
  # manager has no opinion on it, and inventing one here would be this host
  # deciding what the registry should have said.
  for i in 0 ..< gOps.count():
    if not gOps.liveOf(i):
      continue
    let guid = gOps.guidOf(i)
    if guid.len == 0 or knownStranger(guid):
      continue
    var named = false
    for d in want:
      if d.guid == guid:
        named = true
    if named:
      continue
    gStrangers.add guid
    note "the backend's mod set does not mention " & guid &
         ", so this host leaves it exactly as it is"
