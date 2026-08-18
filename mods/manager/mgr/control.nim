## Turning a resolved selection into mods that are actually loaded, while the
## game is running.
##
## **This is the one module in the manager that depends on something that does
## not exist yet.** Per-mod teardown and a control API are being built in the
## host; everything the manager needs from it goes through this file, so when
## that lands the change is here and nowhere else.
##
## Until then it *degrades honestly*: `requestLoad` and `requestUnload` return
## `aoDeferred` with a sentence saying the change is recorded and takes effect on
## restart. They do not pretend, and they do not silently do nothing — a manager
## that reports "enabled" for a mod that is not running is worse than one that
## has no live control at all, because the second is a missing feature and the
## first is a lie you act on.
##
## ---------------------------------------------------------------------------
## The interface this asks the host for
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
## Three properties asked of the host, because without them a manager cannot be
## honest about what it did:
##
##  * `unload` must run the mod's `on_unload`, drop its routes, its event
##    subscriptions and its timers, and free the library — a mod whose routes
##    survive its unload is still serving, and the manager would report it gone.
##  * A mod that cannot be torn down safely (no `mfHotReloadable`, a patch that
##    cannot be reverted) must answer `ok:false, deferred:true` rather than
##    being unloaded anyway. "Takes effect on restart" is a fine answer; a
##    half-unloaded mod is not.
##  * Every request must produce exactly one `result`, including failures.
##    Silence is indistinguishable from a host that never implemented this, and
##    the manager would sit in `csUnknown` forever.
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

var gState = csUnknown
var gHostText = ""
var gLastResults: seq[string] = @[]
var gProbeSent = false

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

proc onCapabilities(payload: string): string =
  let doc = whole(payload)
  let canControl = doc.field("control").asBool(false)
  gHostText = doc.field("host").asText("a host") & " " &
              doc.field("version").asText("")
  if canControl and doc.field("unload").asBool(false):
    gState = csPresent
    success "manager: live mod control is available (" & gHostText & ")"
  else:
    gState = csAbsent
    info "manager: " & gHostText & " answered the control probe but cannot " &
         "unload mods; selection changes will need a restart"
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
  elif deferred:
    note action & " " & guid & ": deferred to restart (" & err & ")"
    warn "manager: " & guid & " cannot be " & action & "ed while running: " & err
  else:
    note action & " " & guid & ": failed (" & err & ")"
    error "manager: " & action & " " & guid & " failed: " & err
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
  var req = obj()
  put(req, "guid", guid)
  put(req, "path", path)
  if broadcast("aowlspt.host.mods.load", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the load request could not be emitted: " &
                                lastError())
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to load " & path)

proc requestUnload*(guid: string): ApplyResult =
  if gState != csPresent:
    return ApplyResult(outcome: aoDeferred, message: unavailableMessage())
  var req = obj()
  put(req, "guid", guid)
  if broadcast("aowlspt.host.mods.unload", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the unload request could not be emitted: " &
                                lastError())
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to unload " & guid)
