## ar/loadoutclient.nim -- THE SERVER HALF: the spawned-loadout handshake.
##
## This runs in the BACKEND process, not in the game. It is the same DLL --
## `sides = {sideClient, sideServer}`, `onLoad` branches on `side()` -- and it
## reads the `config.json` and `loadout.json` sitting beside it in the backend's
## own mod directory. A client mod's config does NOT reach the backend; a
## two-sided mod's does, because it is the same folder.
##
## WHY THIS FILE DOES ALMOST NOTHING
## ---------------------------------
## Everything that actually touches a profile lives in `mods/tarkov` -- which IS
## the SPT-shaped server, and which already has the item builder
## (`emu/loadout.nim`, 1600 lines: template resolution with a REFUSAL on an
## ambiguous name, minting, magazine mounting, cartridge filling, `_required`
## mod slots, grid placement, slot validation, and a PASS/FAIL/INCONCLUSIVE
## report). Reimplementing any of that here would be a second answer to a
## question that already has one, and the second answer is always the one that
## rots.
##
## So this file OWNS THE POLICY and tarkov OWNS THE MECHANISM, and they talk
## over the event bus:
##
##   autoraid  --  autoraid.loadout.apply   -->  tarkov
##                 {"profileId":..,"spec":{clear,gear},"ephemeral":true,
##                  "reason":"tarkov.raid.configured"}
##   tarkov    --  autoraid.loadout.result  -->  autoraid
##                 {"profileId":..,"verdict":"PASS|FAIL|INCONCLUSIVE",
##                  "requested":n,"minted":n,"placed":n,"rejected":n,"why":".."}
##
## WHICH EVENT TRIGGERS IT, AND WHY BOTH ARE SUBSCRIBED
## ----------------------------------------------------
## The loadout has to be in the stored profile BEFORE the client's LAST
## `/client/game/profile/list` fetch, because that route is where the PMC
## Inventory reaches the client (`/client/match/local/start` sends
## `profile: null`). Which of `tarkov.profile.selected` and
## `tarkov.raid.configured` precedes that fetch is a WIRE MEASUREMENT, and this
## mod does not get to guess at it. So `applyAt = auto` -- the shipped value --
## subscribes to BOTH and applies ONCE PER RAID, idempotently: whichever fires
## first wins, the second is a no-op that says so. The two pinned values exist
## for diagnosing the ordering, not for normal use.
##
## THE VERDICT IS A NEGATIVE, AND IT IS TARKOV'S TO EMIT. This file logs
## `AutoRaid LOADOUT VERDICT <verdict>` verbatim from the result event; it does
## not compute its own opinion. The end-of-raid half -- "no minted id remains
## anywhere in the saved profile" -- is likewise tarkov's, for the same reason:
## the only process that can read the saved profile is the one that saved it.

import std/syncio
import aowlspt
import aowlspt/server as sv
import aowlspt/json
import cfg

const
  DedupWindowMs* = 120000'i64
    ## THE IDEMPOTENCE WINDOW, and why it is a window rather than a flag.
    ##
    ## `auto` subscribes to BOTH trigger events, so ONE raid produces two
    ## events a moment apart and only the first may apply. A bare "have we
    ## applied for this profile" flag would achieve that -- and would then
    ## refuse the SECOND RAID of the same session, silently, for the same
    ## profile, which is a bug that only shows up after somebody plays twice.
    ##
    ## Two minutes is far longer than the gap between profile-select and
    ## raid-configuration for one raid (they are consecutive requests) and far
    ## shorter than any real raid, so the window separates "the other trigger
    ## for THIS raid" from "the trigger for the NEXT raid" without needing an
    ## end-of-raid event this mod does not own.

  StatusRoute* = "/aowlspt/autoraid/status"
  ApplyEvent*  = "autoraid.loadout.apply"
  ResultEvent* = "autoraid.loadout.result"
  RaidConfiguredEvent* = "tarkov.raid.configured"
  ProfileSelectedEvent* = "tarkov.profile.selected"

var gSpec = ""              ## loadout.json, verbatim
var gSpecWhy = ""           ## why it is empty, when it is
var gSpecGear = 0           ## entries in it, for the log line
var gApplied = 0            ## applies emitted this session
var gSkipped = 0            ## events that found an apply already done
var gLastProfile = ""       ## the profile the last apply was for (idempotence)
var gLastApplyMs = 0'i64    ## when, so the window below can expire
var gLastReason = ""
var gLastResult = ""        ## the result payload, verbatim
var gLastVerdict = ""

proc slurp(path: string; into: var string): bool =
  ## `readFile` is `{.raises.}` in nimony, so it is wrapped. A missing file and
  ## an unreadable one are the same answer -- both mean "nothing to apply" --
  ## and the caller turns that into a STATED reason, never a silent no-op.
  into = ""
  var f: File
  try:
    if not open(f, path, fmRead): return false
  except:
    return false
  var got = ""
  var ok = false
  try:
    got = readAll(f)
    ok = true
  except:
    ok = false
  try: close(f)
  except: discard
  if not ok: return false
  into = got
  result = true

proc joinp(a, b: string): string =
  if a.len == 0: return b
  if a[a.len - 1] == '\\' or a[a.len - 1] == '/': return a & b
  result = a & "\\" & b

proc loadSpec*() =
  ## Read `loadout.json` beside the mod. Called at load, and its outcome is
  ## logged either way: a spawned mode with no readable spec must not look the
  ## same as `current`.
  gSpec = ""
  gSpecWhy = ""
  gSpecGear = 0
  let path = joinp(modDir(), "loadout.json")
  var body = ""
  if not slurp(path, body):
    gSpecWhy = "could not read " & path
    return
  let doc = whole(body)
  let gear = doc.field("gear")
  if not gear.found or not isArray(gear):
    gSpecWhy = path & " has no `gear` array, so there is nothing to apply. " &
               "The file was READ -- this is a shape problem, not a missing " &
               "file, and the two are different bugs."
    return
  gSpecGear = count(gear)
  if gSpecGear == 0:
    gSpecWhy = path & " has an EMPTY `gear` array. Nothing will be spawned; " &
               "that is a valid thing to ask for, and it is said out loud so " &
               "it cannot be mistaken for a failure."
  gSpec = body

proc specReady*(): bool = gSpec.len > 0
proc specWhy*(): string = gSpecWhy
proc specGear*(): int = gSpecGear

proc buildApply(profileId, reason: string): string =
  ## The `autoraid.loadout.apply` payload. `spec` is the WHOLE of loadout.json,
  ## passed through as RAW json rather than re-serialised: re-encoding somebody
  ## else's document is how a field quietly changes shape, and tarkov's own
  ## `parseSpec` is the one parser that should ever read it.
  var o = obj()
  put(o, "profileId", jstr(profileId))
  put(o, "spec", raw(gSpec))
  put(o, "ephemeral", jbool(true))
  put(o, "reason", jstr(reason))
  result = done(o).text

proc applyFor(profileId, reason: string) =
  ## Emit ONE apply for this raid. IDEMPOTENT: a second event for the same
  ## profile is a no-op that says so, which is what makes subscribing to both
  ## trigger events safe rather than a double-spawn.
  if loadoutMode() != "spawned":
    return
  if not specReady():
    warn "AutoRaid LOADOUT: `loadoutMode` is `spawned` but no usable " &
         "loadout.json was read -- " & gSpecWhy & ". NOTHING was emitted and " &
         "the character goes in with whatever it is wearing. This is a " &
         "REFUSAL, not a silent fall back to `current`."
    return
  if profileId.len == 0:
    warn "AutoRaid LOADOUT: " & reason & " carried no profileId, so there is " &
         "no profile to apply to. NOTHING was emitted."
    return
  let now = nowMs()
  if gLastProfile == profileId and now - gLastApplyMs < DedupWindowMs:
    gSkipped = gSkipped + 1
    info "AutoRaid LOADOUT: " & reason & " fired for profile " & profileId &
         " " & $int(now - gLastApplyMs) & " ms after an apply via " &
         gLastReason & ". Skipped -- ONE apply per raid, idempotently, which " &
         "is what makes subscribing to BOTH trigger events safe. The window " &
         "is " & $int(DedupWindowMs div 1000'i64) & " s, so the NEXT raid in " &
         "this session is applied for normally rather than being silently " &
         "refused as a duplicate."
    return
  gLastProfile = profileId
  gLastApplyMs = now
  gLastReason = reason
  gApplied = gApplied + 1
  if emit(ApplyEvent, buildApply(profileId, reason)) != Ok:
    warn "AutoRaid LOADOUT: the host refused to emit `" & ApplyEvent &
         "`. Nothing will be spawned and mods/tarkov was never asked."
    return
  info "AutoRaid LOADOUT: emitted `" & ApplyEvent & "` for profile " &
       profileId & " (" & $gSpecGear & " gear entr(ies), reason " & reason &
       "). EMITTED IS NOT APPLIED: the verdict is the `" & ResultEvent &
       "` that mods/tarkov sends back, and it is logged verbatim."

proc wants(eventName: string): bool =
  ## Does the configured `applyAt` want this event?
  case applyAt()
  of "raidconfigured":  eventName == RaidConfiguredEvent
  of "profileselected": eventName == ProfileSelectedEvent
  else:                 true          # "auto": both, applied once per raid

proc onRaidConfigured(payload: string): string =
  result = ""
  if not wants(RaidConfiguredEvent): return
  applyFor(asText(field(payload, "profileId"), ""), RaidConfiguredEvent)

proc onProfileSelected(payload: string): string =
  result = ""
  if not wants(ProfileSelectedEvent): return
  applyFor(asText(field(payload, "profileId"), ""), ProfileSelectedEvent)

proc onResult(payload: string): string =
  ## THE LOADOUT VERDICT, logged VERBATIM. This mod does not form its own
  ## opinion about whether the loadout worked: the only process that can read
  ## the saved profile back is the one that saved it, and a second opinion
  ## computed here could only ever be a restatement of what we asked for --
  ## which is a check that cannot fail.
  result = ""
  gLastResult = payload
  gLastVerdict = asText(field(payload, "verdict"), "INCONCLUSIVE")
  let w = asText(field(payload, "why"), "")
  let line = "AutoRaid LOADOUT VERDICT " & gLastVerdict &
             " -- profile " & asText(field(payload, "profileId"), "?") &
             ", requested " & $asInt(field(payload, "requested"), 0) &
             ", minted " & $asInt(field(payload, "minted"), 0) &
             ", placed " & $asInt(field(payload, "placed"), 0) &
             ", rejected " & $asInt(field(payload, "rejected"), 0) &
             (if w.len > 0: ". " & w else: "")
  if gLastVerdict == "PASS":
    success line
  elif gLastVerdict == "FAIL":
    warn line
  else:
    info line & " (INCONCLUSIVE is not a pass: something could not be looked at.)"

proc onStatus(url, body, session: string): string =
  ## `/aowlspt/autoraid/status` -- bare JSON, built with the builders so a path
  ## or a reason containing a quote cannot produce a body that is not JSON.
  ##
  ## It reports the CONFIG and the LAST RESULT and keeps them apart. The two
  ## disagreeing is the interesting case: `mode` spawned with `applies` 0 means
  ## neither trigger event ever reached this mod, which is a completely
  ## different bug from an apply that came back FAIL.
  var o = obj()
  put(o, "mod", jstr("aowl.autoraid"))
  put(o, "side", jstr("server"))
  put(o, "loadoutMode", jstr(loadoutMode()))
  put(o, "applyAt", jstr(applyAt()))
  put(o, "specReady", jbool(specReady()))
  put(o, "specGearEntries", jint(gSpecGear))
  put(o, "specWhy", jstr(gSpecWhy))
  put(o, "applies", jint(gApplied))
  put(o, "skippedDuplicates", jint(gSkipped))
  put(o, "lastProfile", jstr(gLastProfile))
  put(o, "lastReason", jstr(gLastReason))
  put(o, "lastVerdict", jstr(gLastVerdict))
  if gLastResult.len > 0:
    put(o, "lastResult", raw(gLastResult))
  else:
    put(o, "lastResult", jnull())
  result = done(o).text

proc install*(): bool =
  ## Wire the server half. Returns whether every subscription and the route
  ## registered; the caller reports the failures BY NAME, because a mod whose
  ## trigger did not subscribe looks exactly like a mod that was never asked.
  loadSpec()
  var ok = true
  if on(RaidConfiguredEvent, onRaidConfigured) != Ok:
    warn "AutoRaid LOADOUT: could not subscribe to `" & RaidConfiguredEvent &
         "`; a raid configured by the client will not trigger a loadout."
    ok = false
  if on(ProfileSelectedEvent, onProfileSelected) != Ok:
    warn "AutoRaid LOADOUT: could not subscribe to `" & ProfileSelectedEvent &
         "`; profile selection will not trigger a loadout."
    ok = false
  if on(ResultEvent, onResult) != Ok:
    warn "AutoRaid LOADOUT: could not subscribe to `" & ResultEvent &
         "`; a loadout may still be applied but its VERDICT will never be " &
         "logged, which means every run from here is INCONCLUSIVE."
    ok = false
  if sv.serve(StatusRoute, onStatus) != Ok:
    warn "AutoRaid LOADOUT: could not serve " & StatusRoute
    ok = false
  result = ok

proc reportLoadout*() =
  ## One line at load, whatever the mode. Silence here would make `current`
  ## and "the spec failed to load" look identical.
  if loadoutMode() != "spawned":
    info "AutoRaid LOADOUT: mode is `" & loadoutMode() & "` -- this mod does " &
         "NOTHING to your gear and loadout.json was not consulted. Set " &
         "`loadoutMode` to `spawned` to have a kit created for each raid."
    return
  if specReady():
    info "AutoRaid LOADOUT: mode `spawned`, " & $gSpecGear & " gear entr(ies) " &
         "read from loadout.json, trigger `" & applyAt() & "`. Items are " &
         "created for the raid and STRIPPED at match end; the gear you were " &
         "wearing is moved to the stash first, never destroyed."
  else:
    warn "AutoRaid LOADOUT: mode is `spawned` and the spec is NOT usable -- " &
         gSpecWhy & ". No loadout will be applied and this is announced " &
         "rather than falling back to `current` silently."
