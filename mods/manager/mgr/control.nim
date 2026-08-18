## Turning a resolved selection into mods that are actually loaded, while the
## game is running.
##
## Everything the manager knows about *what is running right now* — as against
## what the registry says should run — is in this file. It is the only place the
## manager talks to the host, so a host that grows or loses the facility changes
## this module and nothing else.
##
## ---------------------------------------------------------------------------
## The interface, and which half of it exists
## ---------------------------------------------------------------------------
##
## Deliberately expressed as **events**, not as new ABI functions: the event
## channel already exists on both hosts, needs no `aowlspt_abi.h` change, no ABI
## revision bump, and no rebuild of any mod that does not care. The host becomes
## a subscriber to a reserved `aowlspt.host.*` namespace, and answers by
## emitting.
##
## Request -> reply, all payloads JSON objects:
##
##   `aowlspt.host.mods.probe`     {"from":"<guid>"}
##     -> `aowlspt.host.mods.capabilities`
##        {"host":"aowlspt-backend","version":"0.1.0","control":true,
##         "load":true,"unload":true,"reloadNeedsRestart":false}
##
##   `aowlspt.host.mods.load`      {"guid":"...","path":"<absolute .dll>"}
##   `aowlspt.host.mods.unload`    {"guid":"..."}
##     -> `aowlspt.host.mods.result`
##        {"guid":"...","action":"load"|"unload","ok":true|false,
##         "deferred":false,"error":""}
##
##   `aowlspt.host.mods.list`      {}
##     -> `aowlspt.host.mods.listed`
##        {"mods":[{"guid","name","version","path","live","hotReloadable"}]}
##
## **The mod half of that is implemented here and is complete.** The host half
## is not written yet in either host, and cannot be written from a mod: an event
## emitted by a mod is delivered to *subscribers*, and neither
## `backend/aowlbackend.nim` nor `host/Aowlspt.Host.Il2Cpp/aowlhost.nim`
## subscribes to anything. The exact patch each host needs is written out in
## `host/Aowlspt.Overlay/README.md` under "What the rest of the tree needs to
## change"; `host/common/modhost.nim` already carries the hard part
## (`unloadOne`/`loadOne`/`unloadByGuid` behind `setModTeardown`).
##
## Until a host answers, this degrades honestly: `requestLoad` and
## `requestUnload` return `aoDeferred` with a sentence saying the change is
## recorded and takes effect on restart, and `liveKnown()` stays false so the
## panel says "unknown" rather than inventing a state. A manager that reports
## "enabled" for a mod that is not running is worse than one with no live
## control at all — the second is a missing feature, the first is a lie you act
## on.
##
## Three properties asked of the host, because without them a manager cannot be
## honest about what it did:
##
##  * `unload` must run the mod's `on_unload`, drop its routes, its event
##    subscriptions and its timers, and free the library — a mod whose routes
##    survive its unload is still serving, and the manager would report it gone.
##    That is exactly what `modhost.unloadOne` does, given the teardown the
##    IL2CPP host already has as `dropModRegistrations`.
##  * A mod that cannot be torn down safely (no `mfHotReloadable`, a patch that
##    cannot be reverted) must answer `ok:false, deferred:true` rather than
##    being unloaded anyway. "Takes effect on restart" is a fine answer; a
##    half-unloaded mod is not.
##  * `load` must be **idempotent**: a guid that is already live answers
##    `ok:true` and does nothing. `/aowlspt/mods/apply` states the whole desired
##    set rather than a diff, because the manager cannot know what the host has
##    without asking — and a diff computed from a stale picture is how you get
##    two copies of a mod loaded.
##  * Every request must produce exactly one `result`, including failures.
##    Silence is indistinguishable from a host that never implemented this, and
##    the manager would sit in `csUnknown` forever.
##
## And one the host must get right that is not visible from here: the unload
## must not happen *inside* the emit. `broadcast` is delivered synchronously, so
## the stack at that moment runs through the manager's route handler and
## possibly through the mod being unloaded; freeing its library there is a
## return into unmapped memory. The host queues the request and answers with a
## `result` once it has done the deed off that stack — which is why
## `requestUnload` answers `aoRequested` and not `aoApplied`, and why the panel
## learns the outcome from the next poll rather than from the reply.
##
## If the host would rather add ABI functions than events, the shape needed is
## the same three calls and one capability probe; only the transport changes,
## and only this file.

import aowlspt
import aowlspt/server
import aowlspt/json

type
  ControlState* = enum
    csUnknown   ## the probe has been sent and not yet answered
    csAbsent    ## no host control: changes take effect on restart
    csPresent   ## the host answered and can load and unload

  ApplyOutcome* = enum
    aoRequested ## handed to the host; it will report the result
    aoApplied   ## the host confirmed it
    aoDeferred  ## it cannot take effect until a restart, and says so
    aoRefused   ## it cannot be done at all, and says why

  ApplyResult* = object
    outcome*: ApplyOutcome
    message*: string

  ModState* = object
    ## What the *host* last said about one mod, as against what the registry
    ## says about it. Keyed by guid, and never invented: a guid only gets an
    ## entry once a host has mentioned it in a `listed` or a `result`, or once
    ## the manager has asked for something and been told it cannot happen.
    guid*: string
    live*: bool           ## running in the host right now
    hotReloadable*: bool  ## the host says it can be taken out without a restart
    restart*: bool        ## the last change asked for could not be made live
    pending*: bool        ## a request is out and the host has not answered yet
    message*: string      ## the host's own words, for the row's tooltip/log

var gState = csUnknown
var gHostText = ""
var gLastResults: seq[string] = @[]
var gProbeSent = false
var gStates: seq[ModState] = @[]
var gListKnown = false

proc outcomeName*(o: ApplyOutcome): string =
  if o == aoRequested: return "requested"
  if o == aoApplied: return "applied"
  if o == aoDeferred: return "deferred"
  result = "refused"

proc stateName*(s: ControlState): string =
  if s == csPresent: return "present"
  if s == csAbsent: return "absent"
  result = "unknown"

proc controlState*(): ControlState = gState
proc controlHost*(): string = gHostText
proc recentResults*(): seq[string] = gLastResults

proc liveKnown*(): bool =
  ## True only once a host has answered `aowlspt.host.mods.list`. Everything
  ## that reports "is this mod running" has to consult this first: with no
  ## answer the truthful value is *unknown*, and a panel that renders unknown as
  ## "not loaded" is the same lie as one that renders it as "loaded".
  result = gListKnown

proc note(line: string) =
  gLastResults.add line
  # Bounded: this is a diagnostic tail, not a journal. An unbounded one on a
  # server left up for a week is a leak nobody goes looking for.
  if gLastResults.len > 32:
    var keep: seq[string] = @[]
    for i in gLastResults.len - 32 ..< gLastResults.len:
      keep.add gLastResults[i]
    gLastResults = keep

# ---------------------------------------------------------------------------
# The per-mod state table
# ---------------------------------------------------------------------------
#
# An index-addressed seq rather than a table: nimony has `std/tables`, but every
# lookup here is over a handful of entries and the seq keeps the module free of
# a second container's failure modes. Index loops throughout — binding a loop
# variable to an element of a `seq[object]` and then reading a field of a nested
# seq miscompiles in nimony (see the note in `manager.nim:routeLists`), and one
# style everywhere is easier to trust than two.

proc indexOf(guid: string): int =
  result = -1
  for i in 0 ..< gStates.len:
    if gStates[i].guid == guid:
      return i

proc ensureState(guid: string): int =
  let at = indexOf(guid)
  if at >= 0:
    return at
  gStates.add ModState(guid: guid, live: false, hotReloadable: false,
                       restart: false, pending: false, message: "")
  result = gStates.len - 1

proc isLive*(guid: string): bool =
  ## Only meaningful when `liveKnown()`. False for a guid no host has mentioned,
  ## which is the right answer once a host *has* listed: a guid missing from the
  ## list is a mod that is not there.
  let at = indexOf(guid)
  if at < 0:
    return false
  result = gStates[at].live

proc hotReloadable*(guid: string): bool =
  let at = indexOf(guid)
  if at < 0:
    return false
  result = gStates[at].hotReloadable

proc needsRestart*(guid: string): bool =
  ## The host was asked for this mod and could not do it while running. Set by a
  ## `deferred` result, and cleared by a result that says the change happened.
  let at = indexOf(guid)
  if at < 0:
    return false
  result = gStates[at].restart

proc hostMessage*(guid: string): string =
  let at = indexOf(guid)
  if at < 0:
    return ""
  result = gStates[at].message

proc isPending*(guid: string): bool =
  ## A request is out and the host has not answered. It matters because "what
  ## is running differs from what you asked for" is the definition of *needs a
  ## restart*, and for the second or so between the request and the result it is
  ## also true of a change that is about to succeed. Reporting a restart there
  ## would put a `*` on every row you click, for a moment, every time.
  let at = indexOf(guid)
  if at < 0:
    return false
  result = gStates[at].pending

proc markRequested*(guid: string) =
  let at = ensureState(guid)
  gStates[at].pending = true

proc markRestart*(guid, why: string) =
  ## Recorded rather than derived: only the host knows that a particular mod
  ## cannot be taken out, and the panel has to be able to say so on that row
  ## rather than on the whole list.
  let at = ensureState(guid)
  gStates[at].restart = true
  gStates[at].pending = false
  gStates[at].message = why

proc clearRestart*(guid: string) =
  let at = indexOf(guid)
  if at >= 0:
    gStates[at].restart = false
    gStates[at].pending = false

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

proc parentOf(path: string): string =
  ## The directory containing `path`. Hand-rolled because nimony's strutils has
  ## no `rfind`, and because both separators occur: the host hands out whatever
  ## the platform gave it.
  var cut = -1
  for i in 0 ..< path.len:
    if path[i] == '/' or path[i] == '\\':
      cut = i
  if path.len == 0:
    return ""
  if cut < 0:
    # A path with no separator left is a name in the current directory, and its
    # parent is that directory. Returning "" here instead is what made the
    # registry invisible under `aowl run`, which hands the sim a *relative* mod
    # path -- the real hosts hand over an absolute one and the bug never shows.
    return "."
  if cut == 0:
    return path.substr(0, 0)
  result = path.substr(0, cut - 1)

proc modsRoot*(): string =
  ## The directory the host discovers mods in — the manager's own parent.
  ## Derived rather than configured: the manager is loaded from it, so it is the
  ## one path that cannot be wrong.
  result = parentOf(modDir())

proc libraryPath*(artifactDir, artifactLib: string): string =
  if artifactDir.len == 0 or artifactLib.len == 0:
    return ""
  let root = modsRoot()
  if root.len == 0:
    return ""
  result = root & "/" & artifactDir & "/" & artifactLib

# ---------------------------------------------------------------------------
# The probe, and the replies
# ---------------------------------------------------------------------------

proc requestList*() =
  ## Ask the host what it actually has loaded. Only worth sending to a host that
  ## said it can control mods — one that cannot is also one that has never been
  ## asked to keep a list, and a request that produces no reply would leave
  ## `liveKnown()` false forever, which is already what it is.
  if gState != csPresent:
    return
  var req = obj()
  put(req, "from", "aowl.manager")
  discard broadcast("aowlspt.host.mods.list", req)

proc onCapabilities(payload: string): string =
  let doc = whole(payload)
  let canControl = doc.field("control").asBool(false)
  gHostText = doc.field("host").asText("a host") & " " &
              doc.field("version").asText("")
  if canControl and doc.field("unload").asBool(false):
    gState = csPresent
    success "manager: live mod control is available (" & gHostText & ")"
    # Straight into a list: the capability answer says the host *can* say what
    # is running, and every honest thing the panel prints needs to know it.
    requestList()
  else:
    gState = csAbsent
    info "manager: " & gHostText & " answered the control probe but cannot " &
         "unload mods; selection changes will need a restart"
  result = ""

proc onListed(payload: string): string =
  ## The host's own inventory. It replaces the table rather than merging into
  ## it: a guid the host no longer mentions is a mod that is gone, and merging
  ## would leave it on the panel as live forever.
  let doc = whole(payload)
  let rows = each(doc.field("mods"))
  var next: seq[ModState] = @[]
  for r in rows:
    let guid = r.field("guid").asText("")
    if guid.len == 0:
      continue
    # The restart flag survives the refresh: it is the manager's record of what
    # the host refused, and the host's list does not carry it.
    var wasRestart = false
    var wasPending = false
    var wasMessage = ""
    let at = indexOf(guid)
    if at >= 0:
      wasRestart = gStates[at].restart
      wasPending = gStates[at].pending
      wasMessage = gStates[at].message
    next.add ModState(guid: guid,
                      live: r.field("live").asBool(true),
                      hotReloadable: r.field("hotReloadable").asBool(false),
                      restart: wasRestart,
                      pending: wasPending,
                      message: wasMessage)
  gStates = next
  gListKnown = true
  info "manager: the host reports " & $gStates.len & " loaded mods"
  result = ""

proc onResult(payload: string): string =
  let doc = whole(payload)
  let guid = doc.field("guid").asText("?")
  let action = doc.field("action").asText("?")
  let ok = doc.field("ok").asBool(false)
  let deferred = doc.field("deferred").asBool(false)
  let err = doc.field("error").asText("")
  if ok:
    note action & " " & guid & ": done"
    success "manager: " & action & " " & guid
    # The host did it, so the manager's picture of what is running is now one
    # entry out of date and it is cheaper to fix it here than to re-list.
    let at = ensureState(guid)
    gStates[at].live = action == "load"
    gStates[at].restart = false
    gStates[at].pending = false
    gStates[at].message = ""
  elif deferred:
    note action & " " & guid & ": deferred to restart (" & err & ")"
    warn "manager: " & guid & " cannot be " & action & "ed while running: " & err
    markRestart(guid, err)
  else:
    note action & " " & guid & ": failed (" & err & ")"
    error "manager: " & action & " " & guid & " failed: " & err
    # A failure is not a deferral, but it has the same consequence for the row:
    # what you asked for is not what is running, and the panel must not show it
    # as if it were.
    markRestart(guid, err)
  result = ""

proc onProbeTimeout(payload: string): string =
  if gState == csUnknown:
    gState = csAbsent
    info "manager: no host answered the control probe, so this host has no " &
         "live enable/disable. Selection changes are saved and take effect " &
         "when the host restarts."
  result = ""

proc controlInit*(probeMs: int) =
  ## Subscribe, probe, and arm the timeout that turns silence into an answer.
  ##
  ## Silence has to become `csAbsent` on a timer rather than being assumed:
  ## the manager may load before the host finishes wiring its own subscriptions,
  ## and treating "no reply yet" as "no facility" would make the answer depend
  ## on load order.
  discard onEvent("aowlspt.host.mods.capabilities", onCapabilities)
  discard onEvent("aowlspt.host.mods.result", onResult)
  discard onEvent("aowlspt.host.mods.listed", onListed)

  var probe = obj()
  put(probe, "from", "aowl.manager")
  if broadcast("aowlspt.host.mods.probe", probe) == Ok:
    gProbeSent = true
  var wait = probeMs
  if wait < 1: wait = 1
  discard afterMs(wait, onProbeTimeout)

proc unavailableMessage(): string =
  if gState == csUnknown:
    return "the host has not answered the control probe yet; the change is " &
           "saved and will be in effect at the latest on the next start"
  result = "this host has no live mod control, so the change is saved and " &
           "takes effect when it restarts"

proc requestLoad*(guid, artifactDir, artifactLib: string): ApplyResult =
  if artifactDir.len == 0 or artifactLib.len == 0:
    return ApplyResult(outcome: aoRefused,
                       message: guid & " has no `artifact` block in the " &
                                "registry, so there is no library to load")
  let path = libraryPath(artifactDir, artifactLib)
  if path.len == 0:
    return ApplyResult(outcome: aoRefused,
                       message: "the host did not say where mods live, so " &
                                guid & " cannot be located")
  if gState != csPresent:
    return ApplyResult(outcome: aoDeferred, message: unavailableMessage())
  # Already there, and the host said so itself. Answering `applied` without
  # sending anything is the idempotence `/apply` depends on: it states the whole
  # desired set every time, and a load per already-loaded mod per apply would be
  # a burst of host work for nothing.
  if gListKnown and isLive(guid):
    clearRestart(guid)
    return ApplyResult(outcome: aoApplied, message: guid & " is already loaded")
  var req = obj()
  put(req, "guid", guid)
  put(req, "path", path)
  if broadcast("aowlspt.host.mods.load", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the load request could not be emitted: " &
                                lastError())
  markRequested(guid)
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to load " & path)

proc requestUnload*(guid: string): ApplyResult =
  if gState != csPresent:
    return ApplyResult(outcome: aoDeferred, message: unavailableMessage())
  # Not there. Same reasoning as the load side, and the more important half:
  # without it, every `/apply` would ask the host to unload every mod the
  # registry knows and the player has switched off — which is a stream of
  # "there was nothing there" results that reads like a fault.
  if gListKnown and not isLive(guid):
    clearRestart(guid)
    return ApplyResult(outcome: aoApplied, message: guid & " is not loaded")
  var req = obj()
  put(req, "guid", guid)
  if broadcast("aowlspt.host.mods.unload", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the unload request could not be emitted: " &
                                lastError())
  markRequested(guid)
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to unload " & guid)
