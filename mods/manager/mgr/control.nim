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
## **Both halves exist.** The mod half is this file. The host half is
## `host/common/modcontrol.nim`, and both hosts drive it:
## `backend/aowlbackend.nim` calls `controlInit` before `loadAll` and `drain`
## in its serve loop, on top of `host/common/modhost.nim`'s `unloadOne` and the
## teardown it requires; `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` calls
## `startModControl` after its mods are up and `modcontrol.drain` in its tick
## loop, against its own loader's `unloadOne` and `dropModRegistrations`. So
## enabling and disabling a mod while the game runs works on the server and in
## the game.
##
## **What this file talks to is still only the server's host.** The events below
## are delivered to subscribers *in this process*, and the client host is a
## different process — so `controlState()`, `liveKnown()` and every `ModState`
## here describe the backend and nothing else. The client host is reached the
## other way round: it polls `/aowlspt/mods/client` (see `manager.nim`) and
## applies the answer itself through `modcontrol.applyDesired`. This module
## never learns what happened over there, which is why `isLive` for a
## client-only mod is the *backend's* answer — "not loaded here" — and why the
## panel's `live` column is still the server's view.
##
## Where no host answers, this degrades honestly: `requestLoad` and
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
##    That is exactly what `modhost.unloadOne` does, given a teardown. The
##    backend installs one; the IL2CPP host does the same work in its own
##    `unloadOne`, which runs `on_unload`, calls `dropModRegistrations` to take
##    out that mod's subscriptions, queued callbacks and detours, and only then
##    frees the library.
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
##
## ---------------------------------------------------------------------------
## What is *not* here
## ---------------------------------------------------------------------------
##
## Nothing in this file knows about the client host, and that is the design
## rather than an omission. A process boundary cannot be crossed by an event, so
## the client host asks over HTTP instead, on its own timer, and this manager
## answers the same resolution it would have answered anyone. It is a second
## *reader* of the decisions, not a second decider — which is why adding it cost
## one route in `manager.nim` and not one line here.

import aowlspt
import aowlspt/server
import aowlspt/json
import aowlspt/sync

## ## Which of these hold the mod's lock, and which are held under it
##
## The manager runs one lock over all of its own state (`aowlspt/sync`; the
## whole discipline is written down in the header of `manager.nim`). This
## module sits on both sides of it, and the split is not arbitrary:
##
##  * **Entry points from a host thread** -- the four event handlers -- take the
##    lock themselves, because nothing above them is holding it. They take it
##    for the table work and drop it before emitting or logging.
##  * **Readers** -- `controlState`, `isLive`, `needsRestart`, `hostMessage`,
##    `isPending`, `liveKnown` -- assume it is *already* held, because every
##    caller is a route inside the guarded region. They must not take it: it is
##    documented non-reentrant.
##  * **`requestLoad` and `requestUnload` are called without it**, from
##    `applySelection`, which gives the lock up for exactly this. They take it
##    around their own reads and writes and never hold it across `broadcast`.
##
## That last rule is the one with teeth. `broadcast` is delivered synchronously
## and the host answers a load or an unload by emitting
## `aowlspt.host.mods.result` -- which lands in `onResult`, on this thread,
## wanting the same lock. Holding it across the emit is a self-deadlock, and it
## is one that only happens on the hosts that answer quickly.

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
  ## Assumes the mod lock is held; every caller is inside a guarded region.
  ##
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
  ##
  ## Called *without* the lock: the emit below is answered by the host, and on
  ## a host that answers it synchronously the answer arrives in `onListed` on
  ## this thread.
  var present = false
  withModLock:
    present = gState == csPresent
  if not present:
    return
  var req = obj()
  put(req, "from", "aowl.manager")
  discard broadcast("aowlspt.host.mods.list", req)

proc onCapabilities(payload: string): string =
  ## An entry point: it arrives on whichever thread the host emitted from.
  let doc = whole(payload)
  let canControl = doc.field("control").asBool(false)
  let present = canControl and doc.field("unload").asBool(false)
  var text = ""
  withModLock:
    gHostText = doc.field("host").asText("a host") & " " &
                doc.field("version").asText("")
    text = gHostText
    gState = (if present: csPresent else: csAbsent)
  if present:
    success "manager: live mod control is available (" & text & ")"
    # Straight into a list, and *outside* the lock: the capability answer says
    # the host can say what is running, and every honest thing the panel prints
    # needs to know it -- but the host may answer `listed` on this thread, into
    # a handler that would want the lock this one was still holding.
    requestList()
  else:
    info "manager: " & text & " answered the control probe but cannot " &
         "unload mods; selection changes will need a restart"
  result = ""

proc onListed(payload: string): string =
  ## The host's own inventory. It replaces the table rather than merging into
  ## it: a guid the host no longer mentions is a mod that is gone, and merging
  ## would leave it on the panel as live forever.
  let doc = whole(payload)
  let rows = each(doc.field("mods"))
  var next: seq[ModState] = @[]
  var count = 0
  # Explicit rather than `withModLock`, because the region has a `continue` in
  # it and the template's body must be left the way it was entered.
  lockMod()
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
  count = gStates.len
  unlockMod()
  info "manager: the host reports " & $count & " loaded mods"
  result = ""

proc onResult(payload: string): string =
  let doc = whole(payload)
  let guid = doc.field("guid").asText("?")
  let action = doc.field("action").asText("?")
  let ok = doc.field("ok").asBool(false)
  let deferred = doc.field("deferred").asBool(false)
  let err = doc.field("error").asText("")
  # An entry point, and the one most likely to arrive while a route is reading
  # the same table: the host answers a load or an unload from its own thread,
  # or from the thread that asked, some milliseconds later.
  if ok:
    withModLock:
      note action & " " & guid & ": done"
      # The host did it, so the manager's picture of what is running is now one
      # entry out of date and it is cheaper to fix it here than to re-list.
      let at = ensureState(guid)
      gStates[at].live = action == "load"
      gStates[at].restart = false
      gStates[at].pending = false
      gStates[at].message = ""
    success "manager: " & action & " " & guid
  elif deferred:
    withModLock:
      note action & " " & guid & ": deferred to restart (" & err & ")"
      markRestart(guid, err)
    warn "manager: " & guid & " cannot be " & action & "ed while running: " & err
  else:
    withModLock:
      note action & " " & guid & ": failed (" & err & ")"
      # A failure is not a deferral, but it has the same consequence for the
      # row: what you asked for is not what is running, and the panel must not
      # show it as if it were.
      markRestart(guid, err)
    error "manager: " & action & " " & guid & " failed: " & err
  result = ""

proc onProbeTimeout(payload: string): string =
  var silence = false
  withModLock:
    if gState == csUnknown:
      gState = csAbsent
      silence = true
  if silence:
    info "manager: no host answered the control probe, so this host has no " &
         "live enable/disable. Selection changes are saved and take effect " &
         "when the host restarts."
  result = ""

# ---------------------------------------------------------------------------
# Raid state, relayed to the client host for the graphics post-process gate
# ---------------------------------------------------------------------------
#
# The tarkov mod broadcasts `tarkov.raid.started` when the 3D world begins
# loading (POST /client/match/local/start) and `tarkov.raid.ended` on the way
# out (POST /client/match/local/end). The manager is already the thing the
# client host polls for its mod set, so it is the natural place to fold in one
# more bit of state: whether a raid is in progress. The client host reads
# `inRaid` out of that same poll response and gates the graphics post-process on
# it, so the grade lands on the raid world and the menu stays stock. No new
# endpoint, no new poll — it rides the request that is already being made.

var gInRaid = false

proc raidActive*(): bool =
  ## Whether a raid is in progress, for `routeClient` to report as `inRaid`.
  gInRaid

proc onRaidStarted(payload: string): string =
  gInRaid = true
  result = ""

proc onRaidEnded(payload: string): string =
  gInRaid = false
  result = ""

# ---------------------------------------------------------------------------
# The main menu's bottom-right game-mode label, relayed to the client host
# ---------------------------------------------------------------------------
#
# A stock post-1.0 menu reads "PVE ZONE" down there. The client host can now put
# anything short there instead, by calling the game's own
# `PreloaderUI::SetGameModeText`. What it should say is a question only this side
# can answer, so this is where the answer is assembled — and it rides `inRaid`'s
# poll for `inRaid`'s reasons: the host has one route to the backend, it is
# already using it, and a second channel would be a second thing that can break.
#
# Two inputs, and the precedence between them is the whole design:
#
#   1. `aowlspt.menu.modeText`  -- an OVERRIDE, pushed by any mod. Wins.
#   2. `aowlspt.menu.nickname`  -- the DEFAULT: the logged-in character's name,
#      pushed by the tarkov emulator when a session binds to a profile.
#
# A mod pushing an empty string CLEARS its override and the nickname comes back.
# That matters: "set it back to normal" must be expressible, and a mod that is
# unloaded mid-session should not be able to leave a stale label behind forever.

var gMenuModeOverride = ""
var gMenuNickname = ""

proc menuModeText*(): string =
  ## What `routeClient` reports as `menuModeText`. Empty means "say nothing" --
  ## the host then leaves the stock label exactly where it is, which is the
  ## right answer before anyone has logged in.
  if gMenuModeOverride.len > 0:
    return gMenuModeOverride
  result = gMenuNickname

var gBotNavSpec = ""

proc botNavSpec*(): string = gBotNavSpec
  ## What `routeClient` reports as `botNav`. Empty means "no commands", and the
  ## host then leaves every bot to its own brain -- which is the right answer
  ## before any mod has asked for anything.

proc botNavSane(s: string): bool =
  ## The same shape the host's `parseBotNav` will accept. Checked HERE too,
  ## rather than trusting the far end to reject it: a value that cannot survive
  ## the trip should be refused at the point a mod author can still be told about
  ## it, and a manager that published rubbish the host silently dropped would
  ## look exactly like a manager that was working.
  if s.len > 512:
    return false
  for ch in s:
    let o = ord(ch)
    let okCh = (o >= ord('0') and o <= ord('9')) or
               (o >= ord('a') and o <= ord('z')) or
               ch == '|' or ch == ';' or ch == ',' or ch == '.' or
               ch == '-' or ch == '+' or ch == ' '
    if not okCh:
      return false
  result = true

proc onBotNav(payload: string): string =
  ## `aowlspt.bot.nav` -- `{"spec":"..."}`. An empty or absent `spec` clears the
  ## command set, which is how a mod says "stop steering, hand the bots back".
  ##
  ## Last writer wins, deliberately: this is a command *set*, not a queue. Two
  ## mods both steering the same bot would fight whatever the merge rule was, and
  ## a rule that silently interleaved them would make that fight invisible.
  let t = field(payload, "spec").asText("")
  if t.len == 0:
    gBotNavSpec = ""
  elif botNavSane(t):
    gBotNavSpec = t
  result = ""

var gCensusEmitted = -1

proc emitBotCensusIfChanged*(count: int; census: string) =
  ## Push the client host's bot registry onto the event bus as
  ## `aowlspt.bot.census` -- `{"count":<n>,"census":"..."}` -- whenever a new one
  ## has arrived, and never otherwise.
  ##
  ## Push rather than pull because the bus has no request/response: `broadcast`
  ## returns a `Status`, not a reply, so a mod cannot ask for the census and a
  ## mod that could would be polling a value that only changes when a poll
  ## brings it. Pushing on change is the same information with none of the
  ## spinning.
  ##
  ## Called OUTSIDE the mod lock, deliberately: a subscriber's handler runs on
  ## this thread, and emitting under the lock would let any mod's census handler
  ## deadlock the manager's client route.
  if count == gCensusEmitted:
    return
  gCensusEmitted = count
  var o = obj()
  put(o, "count", count)
  put(o, "census", census)
  discard broadcast("aowlspt.bot.census", o)

proc menuTextSane(s: string): bool =
  ## The same shape the host's `parseMenuModeText` will accept. Checked HERE too,
  ## rather than trusting the far end to reject it: a value that cannot survive
  ## the trip should be refused at the point a person can still be told about it,
  ## and a manager that published rubbish the host silently dropped would look
  ## exactly like a manager that was working.
  if s.len == 0 or s.len > 48:
    return false
  for ch in s:
    if ord(ch) < 0x20 or ord(ch) > 0x7E:
      return false
  result = true

proc onMenuModeText(payload: string): string =
  ## `aowlspt.menu.modeText` — `{"text":"..."}`. An empty or absent `text`
  ## clears the override rather than blanking the label.
  let t = field(payload, "text").asText("")
  if t.len == 0:
    gMenuModeOverride = ""
  elif menuTextSane(t):
    gMenuModeOverride = t
  result = ""

proc onMenuNickname(payload: string): string =
  ## `aowlspt.menu.nickname` — `{"nickname":"..."}`, from the tarkov emulator
  ## when a session binds to a profile. The DEFAULT only; an override still wins.
  let n = field(payload, "nickname").asText("")
  if menuTextSane(n):
    gMenuNickname = n
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
  # Raid state from the tarkov mod, relayed to the client host via routeClient.
  discard onEvent("tarkov.raid.started", onRaidStarted)
  discard onEvent("tarkov.raid.ended", onRaidEnded)
  # The menu's bottom-right game-mode label, same relay. `modeText` is the
  # mod-facing override (see `aowl/src/aowlspt/menutext.nim`); `nickname` is the
  # tarkov emulator naming the character that just logged in, which is the
  # default when no mod has overridden anything.
  discard onEvent("aowlspt.menu.modeText", onMenuModeText)
  # Bot navigation commands from a mod (see `aowl/src/aowlspt/botnav.nim`). The
  # manager holds the set and republishes it on every client poll; the host
  # applies it on the Unity thread inside its guarded per-bot tick.
  discard onEvent("aowlspt.bot.nav", onBotNav)
  discard onEvent("aowlspt.menu.nickname", onMenuNickname)

  var probe = obj()
  put(probe, "from", "aowl.manager")
  if broadcast("aowlspt.host.mods.probe", probe) == Ok:
    gProbeSent = true
  var wait = probeMs
  if wait < 1: wait = 1
  discard afterMs(wait, onProbeTimeout)

proc unavailableMessage(state: ControlState): string =
  ## Takes the state rather than reading it. Both callers already hold a
  ## snapshot of it, and a message that re-reads a global describes a state the
  ## answer beside it was not computed from.
  if state == csUnknown:
    return "the host has not answered the control probe yet; the change is " &
           "saved and will be in effect at the latest on the next start"
  result = "this host has no live mod control, so the change is saved and " &
           "takes effect when it restarts"

proc requestLoad*(guid, artifactDir, artifactLib: string): ApplyResult =
  ## Called **without** the mod lock -- see the note at the top of this file.
  if artifactDir.len == 0 or artifactLib.len == 0:
    return ApplyResult(outcome: aoRefused,
                       message: guid & " has no `artifact` block in the " &
                                "registry, so there is no library to load")
  let path = libraryPath(artifactDir, artifactLib)
  if path.len == 0:
    return ApplyResult(outcome: aoRefused,
                       message: "the host did not say where mods live, so " &
                                guid & " cannot be located")
  # One look at the shared table, one snapshot, and then nothing held. The
  # decision is made from the snapshot rather than by reading the globals again
  # further down: between two reads a `listed` can arrive and turn "not there"
  # into "there", and an answer assembled from both halves describes a state
  # that never existed.
  var state = csUnknown
  var alreadyThere = false
  withModLock:
    state = gState
    alreadyThere = gListKnown and isLive(guid)
    if state == csPresent and alreadyThere:
      clearRestart(guid)
  if state != csPresent:
    return ApplyResult(outcome: aoDeferred, message: unavailableMessage(state))
  # Already there, and the host said so itself. Answering `applied` without
  # sending anything is the idempotence `/apply` depends on: it states the whole
  # desired set every time, and a load per already-loaded mod per apply would be
  # a burst of host work for nothing.
  if alreadyThere:
    return ApplyResult(outcome: aoApplied, message: guid & " is already loaded")
  var req = obj()
  put(req, "guid", guid)
  put(req, "path", path)
  # Emitted with nothing held: the host answers a load by emitting, and a host
  # that answers immediately lands in `onResult` on this thread.
  if broadcast("aowlspt.host.mods.load", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the load request could not be emitted: " &
                                lastError())
  withModLock:
    markRequested(guid)
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to load " & path)

proc requestUnload*(guid: string): ApplyResult =
  ## Called **without** the mod lock, for the same reason as the load side.
  var state = csUnknown
  var notThere = false
  withModLock:
    state = gState
    notThere = gListKnown and not isLive(guid)
    if state == csPresent and notThere:
      clearRestart(guid)
  if state != csPresent:
    return ApplyResult(outcome: aoDeferred, message: unavailableMessage(state))
  # Not there. Same reasoning as the load side, and the more important half:
  # without it, every `/apply` would ask the host to unload every mod the
  # registry knows and the player has switched off — which is a stream of
  # "there was nothing there" results that reads like a fault.
  if notThere:
    return ApplyResult(outcome: aoApplied, message: guid & " is not loaded")
  var req = obj()
  put(req, "guid", guid)
  if broadcast("aowlspt.host.mods.unload", req) != Ok:
    return ApplyResult(outcome: aoRefused,
                       message: "the unload request could not be emitted: " &
                                lastError())
  withModLock:
    markRequested(guid)
  result = ApplyResult(outcome: aoRequested,
                       message: "asked the host to unload " & guid)
