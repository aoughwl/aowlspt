## bridge/bridge.nim -- THE CLIENT HALF OF `aowl.basement`, IN THREE PROCS.
##
## `mods/basement` is one DLL loaded into two processes (the precedent is
## `mods/autoraid`: same DLL, `onLoad` branches on `side()`). The SERVER half
## is `basement.nim` + `bm/*` and owns the world, the brain and the routes.
## THIS half runs inside the game and does exactly the four things
## CLIENT-CONTRACT section 0 lists: report facts, capture speech, execute
## directives, play audio.
##
## The whole surface, so `basement.nim` needs three lines:
##
##     proc bridgeInit*(): Status                  -- from onLoad, client side
##     proc bridgeTick*(elapsedMs: int64)          -- from onUpdate
##     proc bridgeStatusJson*(): JsonObject        -- for /status and the log
##
## THREADING. Everything here runs on the HOST's own ~16 ms loop, never Unity's
## thread, and that is safe BECAUSE it touches no game object: the only host
## verbs it calls (`http`, `http_poll`, `play_wav`, `raid_phase`) are answered
## ABOVE the runtime gate and none of them dereferences a pointer that came
## from the game (`host/Aowlspt.Host.Il2Cpp/hostnet.nim`, banner). Nothing here
## resolves an IL2CPP name, reads a field, calls an RVA or installs a detour --
## so there is no `onMainThread` anywhere in this directory, and there must not
## be one until something is added that needs it.
##
## FILE MAP
##   bridge/core.nim   config, the host-verb wrappers, the refusal ledger
##   bridge/link.nim   the long poll, dispatch by kind, /observe, /ack
##   bridge/say.nim    `say` segments through play_wav, in seq order
##   bridge/spawn.nim  MENU -> GET /spawn -> autoraid.arm
##   bridge/see.nim    raid_started / raid_ended / tick, and only those
##   bridge/hear.nim   push-to-talk POSTs; the KEY is a documented stub
##
## WHAT IS NOT BUILT, ALL OF IT NAMED IN THE FILE THAT WOULD OWN IT:
## `bridge/act.nim` (no bot actuator exists yet) and `bridge/captive.nim`
## (equipment is a profile-side operation in `mods/tarkov`). A directive of
## either kind is ACKED `ok:false` with that sentence -- never ignored.

import aowlspt
import aowlspt/server
import core
import link
import say
import spawn
import see
import hear

var gInit = false
var gLive = false
var gTicks = 0

proc bridgeInit*(): Status =
  ## Called from `onLoad` on the CLIENT side only. Never fails the mod load:
  ## an inert bridge that has said WHY is a correct outcome, and refusing to
  ## load would take the server half down with it.
  loadBridgeConfig()
  gInit = true
  if not bridgeOn():
    info "basement bridge: DISABLED (`bridgeEnabled` is false). Nothing is " &
         "polled, nothing is played, no key is read, and no request leaves " &
         "the game process. Set bridgeEnabled true in the mod's config.json " &
         "AND turn on the host flags `hostHttp` and `hostPlayWav` -- both " &
         "default OFF -- for any of it to do anything."
    return Ok
  if not link.install():
    # `link.install` has already said, by name, what it could not subscribe to.
    return Ok
  spawn.subscribe()
  hear.install()
  see.announceStubs()
  gLive = true
  success "basement bridge: LIVE against " & backendUrl() &
          " (long poll wait " & $pollWaitMs() & " ms, spawnOnMenu " &
          (if spawnOnMenu(): "on" else: "off") & ", ptt key `" &
          pttKeyName() & "` UNREAD -- see the warning above). Every host " &
          "refusal from here on is logged ONCE, naming the flag."
  Ok

proc bridgeTick*(elapsedMs: int64) =
  ## From the mod's `onUpdate`, client side. Cheap when nothing is happening:
  ## the link returns on one boolean when a poll is in flight, and the phase
  ## and spawn polls are on bounded cadences (2 s and 5 s), not per frame.
  if not gLive: return
  gTicks = gTicks + 1
  let now = nowMs()
  link.tick(now)
  say.drain()
  see.tick(now)
  spawn.tick(now)

proc bridgeStatusJson*(): JsonObject =
  ## What the bridge believes, in one object. Read by `/status` on the server
  ## side over the bus, and by a human in the log.
  ##
  ## It reports REFUSALS as prominently as successes, because the question
  ## being asked of this object is almost always "why is nothing happening".
  var o = obj()
  o.put("init", gInit)
  o.put("live", gLive)
  o.put("enabled", bridgeOn())
  o.put("backendUrl", backendUrl())
  o.put("ticks", gTicks)

  var l = obj()
  l.put("state", link.linkState())
  l.put("cursor", cursor())
  l.put("latestSeq", latestSeq())
  l.put("firstSeq", firstSeq())
  l.put("polls", polls())
  l.put("lastPollStatus", lastPollStatus())
  l.put("lastPollError", lastPollError())
  l.put("events", eventsSeen())
  l.put("directives", directivesSeen())
  l.put("unsupported", unsupported())
  l.put("holes", holes())
  o.put("link", l)

  var h = obj()
  h.put("httpVerbMissing", httpVerbMissing())
  h.put("httpFlagOff", httpFlagOff())
  h.put("submitted", submitted())
  h.put("accepted", accepted())
  h.put("refused", refused())
  h.put("completed", completed())
  h.put("lastStatus", lastStatus())
  h.put("lastError", lastHttpError())
  h.put("lastWhy", lastWhy())
  h.put("distinctRefusalsLogged", saidCount())
  o.put("http", h)

  var a = obj()
  a.put("sent", acks())
  a.put("ok", acksOk())
  a.put("observed", observed())
  o.put("acks", a)

  var s = obj()
  s.put("segments", say.segments())
  s.put("played", played())
  s.put("subtitles", subtitles())
  s.put("playRefused", playRefused())
  s.put("flushes", flushes())
  s.put("queued", queued())
  s.put("lastLine", lastLine())
  o.put("say", s)

  var sp = obj()
  sp.put("onMenu", spawnOnMenu())
  sp.put("phase", phaseSeen())
  sp.put("arms", arms())
  sp.put("refusals", spawnRefusals())
  sp.put("map", armedMap())
  sp.put("why", spawnWhy())
  o.put("spawn", sp)

  var se = obj()
  se.put("phase", see.phase())
  se.put("inRaid", inRaid())
  se.put("raidStarted", raidStarts())
  se.put("raidEnded", raidEnds())
  se.put("ticks", ticksSent())
  se.put("stubbed", "player_moved, player_seen, player_aimed_at, " &
         "player_fired, player_hit, npc_died -- no position primitive, no " &
         "shared bot census, no fire/hit detour")
  o.put("see", se)

  var hr = obj()
  hr.put("key", pttKeyName())
  hr.put("keyRead", false)
  hr.put("sessions", pttSessions())
  hr.put("downs", pttDowns())
  hr.put("ups", pttUps())
  hr.put("holding", holding())
  hr.put("stub", "no host verb or SDK API reports key state; drive it with " &
         "the bus event basement.ptt {state}")
  o.put("hear", hr)
  result = o
