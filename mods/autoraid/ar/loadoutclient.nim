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
## (`emu/loadout.nim`: template resolution with a REFUSAL on an ambiguous name,
## minting, magazine mounting, cartridge filling, `_required` mod slots, grid
## placement, slot validation, and a PASS/FAIL/INCONCLUSIVE report).
## Reimplementing any of that here would be a second answer to a question that
## already has one, and the second answer is always the one that rots.
##
## So this file OWNS THE POLICY and tarkov OWNS THE MECHANISM, and they talk
## over the event bus:
##
##   autoraid  --  autoraid.loadout.apply   -->  tarkov
##                 {"profileId":..,"spec":{clear,gear},"ephemeral":true,
##                  "reason":"tarkov.profile.listing"}
##   tarkov    --  autoraid.loadout.result  -->  autoraid
##                 {"profileId":..,"verdict":"PASS|FAIL|INCONCLUSIVE",
##                  "requested":n,"minted":n,"placed":n,"rejected":n,"why":".."}
##
## ===========================================================================
## WHEN THE LOADOUT MUST LAND -- MEASURED, AND IT IS NOT WHERE THIS FILE FIRST
## PUT IT
## ===========================================================================
##
## The PMC Inventory reaches the client at `/client/game/profile/list`, and
## NOWHERE else: `/client/match/local/start` sends `profile: null`
## (`mods/tarkov/tarkov.nim:2381`). So a spawned kit is only in the raid if it
## is in the stored profile BEFORE that fetch is served.
##
## MEASURED by agent S from the real wire capture (`data/capture/raid1`), one
## menu cycle:
##
##     /client/game/profile/list        <-- the ONLY time the Inventory is sent
##     /client/game/profile/select
##     /client/raid/configuration
##     /client/match/local/start
##     /client/match/local/end
##     /client/game/profile/list        <-- the NEXT cycle's fetch
##
## `profile/list` is fetched ONCE per menu cycle and NEVER AGAIN after select or
## configuration. That single fact invalidates the design this file shipped
## with, and it is written down rather than quietly replaced:
##
##   **A loadout applied on `tarkov.raid.configured` or
##   `tarkov.profile.selected` reaches the client on the NEXT menu cycle, not
##   the coming raid.**
##
## It would have "worked" -- one raid late, every time, for ever -- and the
## verdict would still have said PASS, because tarkov really would have minted
## the items into the stored profile. That is the exact shape of a check that
## cannot fail: it asserts our own write and never asks whether the write
## REACHED the client. Nothing in the old design could have caught it. Only the
## wire could, and only agent S looked.
##
## So the trigger is now `tarkov.profile.listing`, which agent S emits
## SYNCHRONOUSLY from inside `onProfileList` BEFORE it serves the profile. A
## subscriber that emits `autoraid.loadout.apply` from inside that handler gets
## the kit minted into the very document the client is about to receive.
## Synchronous is the whole point: an event that merely fired "around then"
## would be a race, and a race that loses is indistinguishable from the bug
## above.
##
## THE OTHER TWO SUBSCRIPTIONS ARE KEPT, AND THEY APPLY NOTHING. They log one
## line saying they are TOO LATE FOR THE COMING RAID. They are kept for two
## reasons: they are the standing evidence that the ordering above still holds
## on a future build, and deleting them would leave the next reader to
## re-derive by experiment the thing this comment exists to state.
##
## IDEMPOTENCE IS PER CYCLE -- not per profile, and not on a clock. `cycle`
## comes in the payload; one `profile/list` is one cycle, and this file applies
## at most once for a given (profileId, cycle). Beyond that it does not need to
## guard: tarkov REFUSES a second mint while a minted set is still active and
## SAYS WHY, and that refusal arrives here as a verdict like any other rather
## than being swallowed.
##
## THE VERDICT IS TARKOV'S TO EMIT. This file logs `AutoRaid LOADOUT VERDICT
## <verdict>` verbatim; it does not compute its own opinion. The end-of-raid
## half -- "no minted id remains anywhere in the saved profile" -- is likewise
## tarkov's, for the same reason: the only process that can read the saved
## profile is the one that saved it.

import std/syncio
import aowlspt
import aowlspt/server as sv
import aowlspt/json
import cfg

const
  StatusRoute* = "/aowlspt/autoraid/status"
  ApplyEvent*  = "autoraid.loadout.apply"
  ResultEvent* = "autoraid.loadout.result"

  ListingEvent* = "tarkov.profile.listing"
    ## THE ONLY TRIGGER THAT WORKS. Emitted SYNCHRONOUSLY from inside
    ## `onProfileList`, BEFORE the profile document is serialised and served,
    ## carrying `{"session":..,"profileId":..,"cycle":N}`. Emitting the apply
    ## from inside this handler puts the minted items in the document the
    ## client is about to receive.

  RaidConfiguredEvent* = "tarkov.raid.configured"
    ## INFORMATIONAL ONLY. Fires AFTER the profile has already been served, so
    ## a loadout applied here would land in the NEXT menu cycle's fetch.
  ProfileSelectedEvent* = "tarkov.profile.selected"
    ## INFORMATIONAL ONLY, for the same measured reason.

var gSpec = ""              ## loadout.json, verbatim
var gSpecWhy = ""           ## why it is empty, when it is
var gSpecGear = 0           ## entries in it, for the log line
var gApplied = 0            ## applies emitted this session
var gSkipped = 0            ## listings that found this cycle already applied
var gLate = 0               ## informational (too-late) events observed
var gLastProfile = ""       ## the profile the last apply was for
var gLastCycle = -1         ## ...and the cycle, which is what makes it unique
var gLastReason = ""
var gLastResult = ""        ## the result payload, verbatim
var gLastVerdict = ""
var gSaidLate = false       ## the "these two are too late" line, once per run

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

proc onProfileListing(payload: string): string =
  ## THE ONLY HANDLER THAT APPLIES ANYTHING.
  ##
  ## SYNCHRONOUS, and everything about this proc depends on that: it runs
  ## INSIDE `onProfileList`, before the profile document is serialised. The
  ## `emit` below is therefore not a notification -- it is a call, and by the
  ## time it returns the items are in the profile the client is about to be
  ## handed. Anything moved out of this call stack (a timer, a queue, a "do it
  ## soon") reintroduces the one-raid-late bug this replaced.
  result = ""
  if loadoutMode() != "spawned":
    return
  if applyAt() == "off":
    info "AutoRaid LOADOUT: " & ListingEvent & " fired and `applyAt` is " &
         "`off`, so NOTHING was applied. That is a diagnostic setting, not a " &
         "failure -- set it back to `listing` to have the kit minted."
    return
  if not specReady():
    warn "AutoRaid LOADOUT: `loadoutMode` is `spawned` but no usable " &
         "loadout.json was read -- " & gSpecWhy & ". NOTHING was emitted and " &
         "the character goes in with whatever it is wearing. This is a " &
         "REFUSAL, not a silent fall back to `current`."
    return
  let profileId = asText(field(payload, "profileId"), "")
  if profileId.len == 0:
    warn "AutoRaid LOADOUT: " & ListingEvent & " carried no profileId, so " &
         "there is no profile to apply to. NOTHING was emitted."
    return
  let cycle = asInt(field(payload, "cycle"), -1)
  if cycle >= 0 and profileId == gLastProfile and cycle == gLastCycle:
    gSkipped = gSkipped + 1
    info "AutoRaid LOADOUT: " & ListingEvent & " fired again for profile " &
         profileId & " cycle " & $cycle & ", which has already been applied " &
         "for. Skipped -- ONE apply per CYCLE. Note that is per CYCLE and not " &
         "per profile: the next menu cycle is the next raid and is applied " &
         "for normally."
    return
  gLastProfile = profileId
  gLastCycle = cycle
  gLastReason = ListingEvent & " (cycle " & $cycle & ")"
  gApplied = gApplied + 1
  if emit(ApplyEvent, buildApply(profileId, ListingEvent)) != Ok:
    warn "AutoRaid LOADOUT: the host refused to emit `" & ApplyEvent &
         "`. Nothing will be spawned and mods/tarkov was never asked."
    return
  info "AutoRaid LOADOUT: emitted `" & ApplyEvent & "` for profile " &
       profileId & " cycle " & $cycle & " (" & $gSpecGear & " gear " &
       "entr(ies)), from INSIDE " & ListingEvent & " -- so the items land in " &
       "the /client/game/profile/list document the client is about to " &
       "receive, which the wire capture shows is the ONLY time the PMC " &
       "Inventory is sent. EMITTED IS NOT APPLIED: the verdict is the `" &
       ResultEvent & "` mods/tarkov sends back, logged verbatim."

proc noteTooLate(eventName: string) =
  ## The two informational subscriptions. THEY APPLY NOTHING.
  ##
  ## Kept rather than deleted because they are the standing evidence that the
  ## measured order still holds: if a future build ever fetched profile/list
  ## after one of these, the fix would start here. Said ONCE per run, because
  ## the fact does not change and a line per raid is noise.
  gLate = gLate + 1
  if gSaidLate: return
  gSaidLate = true
  info "AutoRaid LOADOUT: `" & eventName & "` fired. This is OBSERVED AND NOT " &
       "ACTED ON, and that is a measurement rather than an oversight: agent " &
       "S's wire capture shows /client/game/profile/list is fetched ONCE per " &
       "menu cycle and NEVER after select or configuration, so a loadout " &
       "applied here would reach the client on the NEXT menu cycle -- one " &
       "raid late, every time, while still reporting PASS. The apply happens " &
       "inside `" & ListingEvent & "` instead."

proc onRaidConfigured(payload: string): string =
  result = ""
  if loadoutMode() != "spawned": return
  noteTooLate(RaidConfiguredEvent)

proc onProfileSelected(payload: string): string =
  result = ""
  if loadoutMode() != "spawned": return
  noteTooLate(ProfileSelectedEvent)

proc onResult(payload: string): string =
  ## THE LOADOUT VERDICT, logged VERBATIM. This mod does not form its own
  ## opinion about whether the loadout worked: the only process that can read
  ## the saved profile back is the one that saved it, and a second opinion
  ## computed here could only ever be a restatement of what we asked for --
  ## which is a check that cannot fail.
  ##
  ## A REFUSAL IS A VERDICT TOO. tarkov declines a second mint while a minted
  ## set is still active and says why; that answer arrives here like any other
  ## and is logged, never swallowed.
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
  ## It reports the CONFIG and the LAST RESULT and keeps them apart. The
  ## interesting disagreement is `applies` 0 with `tooLateEvents` non-zero:
  ## that means `tarkov.profile.listing` never reached this mod while the other
  ## two did -- an older mods/tarkov -- which is a completely different bug
  ## from an apply that came back FAIL.
  var o = obj()
  put(o, "mod", jstr("aowl.autoraid"))
  put(o, "side", jstr("server"))
  put(o, "loadoutMode", jstr(loadoutMode()))
  put(o, "applyAt", jstr(applyAt()))
  put(o, "trigger", jstr(ListingEvent))
  put(o, "specReady", jbool(specReady()))
  put(o, "specGearEntries", jint(gSpecGear))
  put(o, "specWhy", jstr(gSpecWhy))
  put(o, "applies", jint(gApplied))
  put(o, "skippedSameCycle", jint(gSkipped))
  put(o, "tooLateEvents", jint(gLate))
  put(o, "lastProfile", jstr(gLastProfile))
  put(o, "lastCycle", jint(gLastCycle))
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
  if on(ListingEvent, onProfileListing) != Ok:
    warn "AutoRaid LOADOUT: could NOT subscribe to `" & ListingEvent &
         "`. That is the ONLY event from which a loadout can reach the coming " &
         "raid, so with it unsubscribed NOTHING will ever be spawned -- the " &
         "other two subscriptions apply nothing by design. If this " &
         "mods/tarkov predates that event, that is a VERSION MISMATCH and not " &
         "a bug here; the status route reports `applies` 0 with " &
         "`tooLateEvents` climbing, which is exactly that shape."
    ok = false
  if on(RaidConfiguredEvent, onRaidConfigured) != Ok:
    warn "AutoRaid LOADOUT: could not subscribe to `" & RaidConfiguredEvent &
         "` (informational only; nothing is ever applied from it)."
    ok = false
  if on(ProfileSelectedEvent, onProfileSelected) != Ok:
    warn "AutoRaid LOADOUT: could not subscribe to `" & ProfileSelectedEvent &
         "` (informational only; nothing is ever applied from it)."
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
         "read from loadout.json, applied from INSIDE `" & ListingEvent &
         "` -- the synchronous event mods/tarkov emits before it serves " &
         "/client/game/profile/list, which the wire capture shows is the ONLY " &
         "time the PMC Inventory is sent. `" & RaidConfiguredEvent & "` and `" &
         ProfileSelectedEvent & "` are observed and NEVER applied from: both " &
         "are after that fetch, so a loadout applied there would arrive one " &
         "raid late while still reporting PASS. Items are created for the " &
         "raid and STRIPPED at match end; the gear you were wearing is moved " &
         "to the stash first, never destroyed."
  else:
    warn "AutoRaid LOADOUT: mode is `spawned` and the spec is NOT usable -- " &
         gSpecWhy & ". No loadout will be applied and this is announced " &
         "rather than falling back to `current` silently."
