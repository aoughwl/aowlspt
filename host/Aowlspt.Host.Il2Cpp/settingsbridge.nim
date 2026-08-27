# settingsbridge.nim -- makes a CLIENT-SIDE mod's settings page reachable.
#
# THE DEFECT THIS EXISTS FOR. The F12 nav is built from
# `GET /aowlspt/settings/index`, which `mods/settingshub` fills by broadcasting
# `SettingsIndexQuery` in ITS OWN PROCESS. settingshub is `sides = {sideServer}`,
# so that broadcast only ever reaches mods loaded in the backend. `mods/graphics`
# is `sides = {sideClient}` -- twenty fully wired settings -- and `mods/admin`
# and `mods/fov` have client-only halves. None of them were in the index, so
# none of them had a page in F12 AT ALL. It was never a rendering fault: the
# mods live in a process with no HTTP listener, because the client host refuses
# `route_register` outright.
#
# WHY NOT JUST GIVE graphics A SERVER SIDE. Because the page would appear and
# the edits would not work: the write would persist in the backend's process
# while the runtime being configured lives here. A control that moves and
# changes nothing is worse than an absent one.
#
# WHAT THIS DOES INSTEAD. It runs the same broadcast HERE, over the event bus,
# which the client host does implement (`aowlspt_nim_event_emit`):
#
#   1. `SettingsIndexQuery`  -> every client mod that declared settings answers
#      `SettingsIndexAnnounce` (guid, name, count, done).
#   2. `SettingsPageQuery <guid>` -> that mod answers `SettingsPageAnnounce`
#      with the same rows its (dead) GET route would have served.
#   3. one POST per mod to `/aowlspt/settings/client/sync`, so settingshub can
#      list it in the index and answer its page off a fallback prefix. The
#      overlay needs no change: it keeps fetching `/aowlspt/settings/<guid>`.
#   4. that POST's reply carries any edits made in F12 since the last sync.
#      Each is emitted back at the owning mod as `SettingsApplyQuery`, which
#      persists it AND runs the mod's hot-apply hook -- in this process, where
#      the runtime is. The next cycle pushes the RE-READ rows up, so the panel
#      shows what the mod kept, never what was asked for (fact #135).
#
# `include`d into `aowlhost.nim` after `gSyncMs` and after `modsettingsrender`,
# whose `modSetQueueWrite` shares the single POST slot -- see `gSbYieldUntil`.
#
# SAFETY: touches no IL2CPP and no game memory at all; it is JSON and one HTTP
# POST armed for the overlay's worker thread. Runs on the host tick thread,
# never Unity's. Bounded: at most `cSbMaxMods` mods, one POST per tick, at most
# `cSbMaxPending` edits drained per cycle, and a body larger than the POST
# slot's buffer is REFUSED WITH A LOG LINE rather than silently truncated.
# Self-disables after `cSbMaxFaults`.

const
  cSbPeriodMs = 5000'u64    ## a full collect+push cycle, at most this often
  cSbMaxMods = 16
  cSbMaxPending = 16
  cSbMaxFaults = 6
  cSbStallMs = 12000'u64
  cSbYieldMs = 3000'u64     ## keep off the POST slot this long after a user edit
  cSbBodyMax = 65000        ## must stay under AOWL_OV_POST_BODY in aowlspt_overlay.h

type
  SbMod = object
    guid, name: string
    count, done: int
    rows: string

  SbPhase = enum
    sbIdle
    sbPushing

var gSbOn = true
var gSbOff = false
var gSbFaults = 0
var gSbPhase = SbPhase.sbIdle
var gSbNextMs = 0'u64
var gSbArmedAt = 0'u64
var gSbMods: seq[SbMod] = @[]
var gSbIdx = 0
var gSbCycles = 0
var gSbLastPushed = 0

proc sbFault(why: string) =
  inc gSbFaults
  warn "client settings bridge: " & why & " (fault " & $gSbFaults & "/" &
       $cSbMaxFaults & ")"
  if gSbFaults >= cSbMaxFaults:
    gSbOff = true
    warn "client settings bridge: disabled for this session after " &
         $cSbMaxFaults & " faults; client-side mods will not appear in the " &
         "F12 settings nav until the game is restarted"

var gSbSaid = ""
var gSbSaidAt = 0'u64

proc sbSay(now: uint64; what: string) =
  ## THE ANTI-SILENCE RULE (CLAUDE.md 6). Every terminating branch of `sbTick`
  ## ends here, so "the bridge did nothing" is never a state you have to infer
  ## from an absent line. Says it the first time and on every CHANGE, and
  ## re-states an unchanged condition once a minute so a log opened late still
  ## carries the reason. Not per tick: that would bury the log.
  if what == gSbSaid and gSbSaidAt > 0'u64 and now - gSbSaidAt < 60000'u64:
    return
  gSbSaid = what
  gSbSaidAt = now
  okLog "client settings bridge: " & what

proc sbParseInt(s: string): int =
  ## Digits only, no sign: every field this reads is a non-negative count that
  ## the SDK wrote. A non-numeric field yields 0 rather than a guess.
  result = 0
  for ch in s:
    if ch >= '0' and ch <= '9':
      result = result * 10 + (int(ch) - int('0'))
    else:
      return 0

proc sbJsonStr(s: string): string =
  ## Minimal JSON string escaping for the guid/name fields we build by hand.
  result = "\""
  for ch in s:
    if ch == '"' or ch == '\\':
      result.add '\\'
      result.add ch
    elif ch == '\n' or ch == '\r' or ch == '\t':
      result.add ' '
    else:
      result.add ch
  result.add '"'

proc sbCollect() =
  ## One synchronous broadcast round: who has settings here, and what are their
  ## rows. No network, no game memory -- `deliverEvent` calls every subscriber
  ## before returning, so both answers are complete when this returns.
  gSbMods = @[]
  gSbIndex = @[]
  gSbCollecting = true
  hostEmit(SbIndexQuery, "")
  var announced = gSbIndex
  gSbIndex = @[]
  for a in announced:
    if gSbMods.len >= cSbMaxMods:
      break
    var guid = ""
    var name = ""
    var count = ""
    var doneN = ""
    discard pathGet(a, "guid", guid)
    discard pathGet(a, "name", name)
    discard pathGet(a, "count", count)
    discard pathGet(a, "done", doneN)
    if guid.len == 0:
      continue
    gSbMods.add SbMod(guid: guid,
                      name: (if name.len > 0: name else: guid),
                      count: sbParseInt(count),
                      done: sbParseInt(doneN),
                      rows: "")
  # The rows, one query per mod. Separate loop so a mod that answers the index
  # but not the page is visible as a mod with no rows rather than dropping the
  # whole cycle.
  for i in 0 ..< gSbMods.len:
    gSbPage = ""
    hostEmit(SbPageQuery, gSbMods[i].guid)
    if gSbPage.len == 0:
      continue
    var rows = ""
    var vs = 0
    var ve = 0
    if locatePath(gSbPage, "rows", vs, ve):
      rows = gSbPage.substr(vs, ve - 1)
    gSbMods[i].rows = rows
  gSbCollecting = false
  gSbIdx = 0
  inc gSbCycles

proc sbApplyPending(reply: string) =
  ## The edits settingshub queued for us, applied HERE, in the process that
  ## owns the mod. Each one goes out as `SettingsApplyQuery`, which the SDK
  ## turns into the same `applySettingFromBody` the GET/POST route would have
  ## used, plus the mod's hot-apply hook.
  var items: seq[string] = @[]
  if not pathItems(reply, "pending", items):
    return
  var n = 0
  for it in items:
    if n >= cSbMaxPending:
      warn "client settings bridge: more than " & $cSbMaxPending &
           " queued edits in one reply; the rest arrive on the next cycle"
      break
    var guid = ""
    discard pathGet(it, "guid", guid)
    if guid.len == 0:
      continue
    gSbApply = ""
    # THE CAPTURE GATE MUST BE OPEN FOR THIS EMIT.
    #
    # `sbCapture` drops every announce while `gSbCollecting` is false, and
    # `sbCollect` -- the only place that used to raise it -- has long since
    # returned by the time an edit is applied: applying happens in
    # `SbPhase.sbPushing`, from the POST reply. So `SettingsApplyAnnounce` was
    # emitted correctly by the mod, delivered correctly by the bus, and thrown
    # away here; `gSbApply` stayed empty and every edit on every client-side
    # mod was reported as "nobody answered". The mod HAD answered, and had
    # already persisted the value -- what was lost was only the ack, but the
    # panel re-reads through the same queue and shows the old value, so the
    # control snapped back. Measured 2026-08-27 against a live client:
    # `POST /aowlspt/settings/aowl.debug` at 0:03:45.688, the warn at
    # 0:03:46.297.
    gSbCollecting = true
    hostEmit(SbApplyQuery, it)
    gSbCollecting = false
    if gSbApply.len == 0:
      # NO GUESS. The old text said "the mod may have been unloaded", which was
      # a hypothesis printed as a cause -- and it was wrong for every one of
      # the observed cases, where the mod was loaded and in the nav.
      sbFault("no subscriber answered " & SbApplyQuery & " for '" & guid &
              "' -- the edit is NOT applied; cause unknown from here")
    else:
      var okTxt = ""
      discard pathGet(gSbApply, "ok", okTxt)
      if okTxt == "true":
        okLog "client settings bridge: applied an F12 edit to '" & guid & "'"
      else:
        var err = ""
        discard pathGet(gSbApply, "err", err)
        sbFault("'" & guid & "' refused an F12 edit: " &
                (if err.len > 0: err else: "no reason given"))
    inc n

proc sbTick(now: uint64) =
  ## One bounded step per host tick. Never loops on the network and never
  ## blocks: it either arms a POST or reads one that already landed.
  if gSbOff:
    return
  if not gSbOn:
    sbSay(now, "OFF -- gSbOn is false; no client-side mod page will be published")
    return
  if gSyncMs <= 0:
    # NO POST CHANNEL. `gSyncMs` is only set when `aowlspt-host.json` has a
    # `backendPort` AND a non-zero `modSyncMs`; without it the overlay worker
    # has no backend to POST to. This was one of the four candidate causes and
    # it used to return in total silence.
    sbSay(now, "no backend channel (gSyncMs is 0 -- backendPort missing or " &
               "modSyncMs is 0 in aowlspt-host.json), so no client-side " &
               "settings page can be pushed")
    return
  case gSbPhase
  of SbPhase.sbIdle:
    if now < gSbNextMs:
      return
    sbCollect()
    gSbNextMs = now + cSbPeriodMs
    if gSbMods.len == 0:
      # Not a fault. A host with no client-side mod that declares settings is
      # the normal case on a bare install, and saying "0 mods" every five
      # seconds would bury the log.
      # Not a fault -- a bare install has no client-side mod with settings.
      # But it MUST keep saying so: the old code said it only on cycle 1, which
      # is the tick right after host start, BEFORE the mods have loaded, so the
      # one honest line was also the least informative one and nothing was ever
      # printed again.
      sbSay(now, "0 client-side mods answered " & SbIndexQuery &
                 " (cycle " & $gSbCycles & "); nothing to publish")
      return
    gSbPhase = SbPhase.sbPushing
    gSbLastPushed = 0
  of SbPhase.sbPushing:
    if gSbIdx >= gSbMods.len:
      sbSay(now, "published " & $gSbLastPushed & " of " & $gSbMods.len &
                 " client-side settings page(s) to the backend")
      gSbPhase = SbPhase.sbIdle
      return
    if overlayPostPending():
      if gSbArmedAt > 0'u64 and now - gSbArmedAt > cSbStallMs:
        sbFault("a client settings push to the backend never came back")
        gSbArmedAt = 0'u64
        gSbIdx = gSbIdx + 1
      return
    if gSbArmedAt > 0'u64:
      # A push we armed has completed -- read it before anything else can.
      let (got, ok, body) = overlayPostTake()
      gSbArmedAt = 0'u64
      if got and ok:
        inc gSbLastPushed
        sbApplyPending(body)
      elif got:
        sbFault("the backend refused a client settings push for '" &
                gSbMods[gSbIdx].guid & "'")
      else:
        sbFault("a client settings push for '" & gSbMods[gSbIdx].guid &
                "' produced no answer to read")
      gSbIdx = gSbIdx + 1
      return
    if now < gSbYieldUntil:
      # A user edit on a NATIVE settings page owns the shared POST slot right
      # now (`modSetQueueWrite`). Wait rather than arming over it -- arming
      # over an in-flight write is how an edit gets silently lost.
      return
    let m = gSbMods[gSbIdx]
    var body = "{\"guid\":" & sbJsonStr(m.guid) & ",\"name\":" &
               sbJsonStr(m.name) & ",\"count\":" & $m.count & ",\"done\":" &
               $m.done & ",\"rows\":" & (if m.rows.len > 0: m.rows else: "[]") &
               "}"
    if body.len > cSbBodyMax:
      # REFUSED, not truncated. `aowl_ov_post_start` copies into a fixed buffer
      # and would cut this in half silently, and half a schema parses as a
      # short schema -- a page that renders with rows missing and no error is
      # exactly the failure this file exists to remove.
      sbFault("'" & m.guid & "' has a schema of " & $body.len &
              " bytes, over the " & $cSbBodyMax & "-byte POST body limit; " &
              "its page is NOT published rather than published cut in half")
      gSbIdx = gSbIdx + 1
      return
    overlayPostStart("/aowlspt/settings/client/sync", body)
    gSbArmedAt = now
