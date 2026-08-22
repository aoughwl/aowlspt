## aowlspt/botnav — enumerate the bots in a raid and tell one where to go.
##
## Bot AI runs entirely in the CLIENT, inside `GameAssembly.dll`. Post-1.0 EFT is
## IL2CPP, so there is no BepInEx and no Mono patching, and **reflection is dead**
## — `il2cpp_object_get_class`, `il2cpp_class_get_name` and field iteration all
## fault. What is left is raw static-offset field access and direct calls to
## methods at their static RVA, and that is exactly what the client host does on
## a mod's behalf here.
##
##     import aowlspt/botnav
##
##     proc onCensus(payload: string): string =
##       # Fires whenever the client host reports a new bot registry.
##       for b in botsFromEvent(payload):
##         if b.alive and b.navStatus != 2:
##           # Walk every living bot ten metres east of wherever it is now.
##           discard sendBotTo(b.id, b.x + 10.0, b.y, b.z, reach = 2.0)
##       result = ""
##
##     proc onLoad(): Status =
##       discard onBotCensus(onCensus)
##       # Or, without waiting for a census: send every bot to one spot,
##       # sprinting, and keep them going there for 30 seconds.
##       sendBotsTo(BotNavAll, 213.5, 1.4, -58.2,
##                  reach = 2.0, sprint = true, holdMs = 30000)
##
##     proc onUnload(): Status =
##       clearBotNav()
##
## ---------------------------------------------------------------------------
## How it actually gets there
## ---------------------------------------------------------------------------
##
## Commands go out, and the registry comes back, on the poll the client host
## **already** makes every `modSyncMs` — the same request `menuModeText` and
## `inRaid` ride. No new endpoint, no new poll, no new socket: the client host
## has exactly one route to the backend and a second one would only be a second
## thing that can be down.
##
##     mod --sendBotTo--> aowlspt.bot.nav --> mod manager
##       manager --> GET /aowlspt/mods/client/<hostver> {"botNav":"7|213.5|..."}
##         client host --> EFT.BotOwner::GoToPoint(<Vector3>, ...)   [Unity thread]
##
##     client host --> GET .../client/<hostver>?bn=<census>  --> manager
##       manager --broadcast--> aowlspt.bot.census --> mod's onBotCensus
##
## The census is PUSHED rather than offered for polling, because the event bus
## has no request/response — `broadcast` returns a `Status`, not a reply — and
## because the value only changes when a poll brings a new one, so a mod polling
## it would just be spinning. The same census is also on
## `GET /aowlspt/mods/clientreport` as `botNav`, for anything outside the process.
##
## The host's side of this is a detour on `EFT.BotOwner::UpdateManual`, which the
## game calls once per live bot per frame with the `BotOwner` in RCX. That single
## hook is both the census (every bot announces itself; nothing is enumerated and
## no pointer is kept across frames) and the service tick (a bot's command is
## issued while that bot's own Update runs).
##
## ---------------------------------------------------------------------------
## What to expect — read this before building on it
## ---------------------------------------------------------------------------
##
## * **The player must opt in.** The host side is gated on `botNav` in
##   `aowlspt-host.json`, default `false`. A mod calling this on an install that
##   has not enabled it changes nothing, and that is not an error. Unlike
##   `botDiag`, this feature calls into and writes to live game objects, which is
##   why it is off by default and why the host self-disables it after eight
##   trapped faults.
##
## * **A nav command is ADVISORY, not authoritative.** This is the important
##   limitation and it is not going away without a much larger piece of work. The
##   bot's brain (`BotOwner.Brain`, a layered decision graph) re-evaluates its
##   goal every tick and will happily re-target the mover a frame later. A single
##   "go here" is therefore often overridden almost immediately. The host
##   compensates by RE-ISSUING an active command every 500 ms until it expires or
##   the bot arrives — which is why commands carry a `holdMs` rather than being
##   fire-and-forget. Expect a bot to argue with you, and expect a bot that is in
##   combat to ignore you entirely.
##
## * **Reachability is answered, not guessed.** `EFT.BotOwner::GoToPoint` returns
##   a `NavMeshPathStatus`, and the host reports it back per bot as `navStatus`:
##   `0` complete, `1` partial, `2` invalid (no path to that point), `-1` nothing
##   issued yet, `-2` the host refused to issue because the bot's mover was not
##   ready. A command that comes back `2` is dropped rather than retried — saying
##   it again will not change the navmesh's mind.
##
## * **A bot must have moved at least once** before the host will command it. The
##   game's mover throws a managed `NullReferenceException` if its state machine
##   is not populated, and having seen the bot actually move is the only proof
##   available that it is. A freshly spawned bot is therefore briefly
##   uncommandable, and that is deliberate.
##
## * **The census is PARTIAL and it ROTATES.** This is the constraint most likely
##   to surprise you. The host's whole report path is capped at 191 characters —
##   the overlay's sync worker copies it into a 192-byte field and truncates
##   silently past that — which is nowhere near a full registry. So each census
##   carries roughly the first five bots that fit, starting where the last one
##   stopped, and works through the rest on later polls. Every bot is reported
##   within a few polls and none can be starved, but **a bot missing from one
##   census is not a bot that has left the raid**. Accumulate across censuses,
##   keyed on `id`, and age entries out rather than treating each payload as the
##   complete picture.
##
## * **Positions are stale and rounded.** They are as of the host's last report,
##   rebuilt at most every 4 seconds, carried on a poll that runs every
##   `modSyncMs` (default 3 s), and rounded to whole metres to fit the budget
##   above. This is a control channel, not a telemetry stream; do not build
##   anything that needs a bot's position this frame or to sub-metre precision.
##
## * **Last writer wins.** There is one command set. Two mods both steering the
##   same bot is two mods fighting, and the manager holds whichever spoke last
##   rather than interleaving them invisibly.
##
## * **What is NOT here.** Behaviour tuning (SAIN-style) is not reachable this
##   way at all — that lives in the brain's decision layers, which cannot be
##   subclassed without reflection. Multi-waypoint routes are not native either:
##   the game's `GoToByWay` takes a managed `Vector3[]`, so build a route as a
##   sequence of `sendBotTo` calls and advance when the bot arrives.

import ".." / aowlspt            # Status, Ok, ErrBadArg, EventHandler
import "." / server              # broadcast, objOf, onEvent
import "." / json                # field, asText

const
  BotNavAll* = -1
    ## Address a command to every registered bot rather than one id.
  BotNavMaxSpec* = 512
    ## The longest command string this will send. Matches `BotNavMax` in the
    ## client host's `modcontrol.nim`, and both exist so the limit is enforced at
    ## the end where it can still be reported rather than only at the end where
    ## it can only be dropped.
  BotNavMaxCommands* = 16
    ## The most commands one set may carry. The host's registry applies them in
    ## order; anything past this is dropped.

type
  BotInfo* = object
    ## One bot, as of the client host's last report.
    id*: int          ## `EFT.BotOwner.Id` — the handle every command takes.
    role*: int        ## `WildSpawnType` as an int32. Raw on purpose: the enum's
                      ## members move between builds and a stale name mapping
                      ## would be worse than an honest number.
    difficulty*: int  ## `BotDifficulty` as an int32, same reasoning.
    alive*: bool
    x*, y*, z*: float
    navStatus*: int   ## Last `NavMeshPathStatus` for this bot: 0 complete,
                      ## 1 partial, 2 invalid, -1 none issued, -2 host refused.

  BotCommand* = object
    ## One instruction, for `sendBotCommands`. Build these with `goTo`, `stop`
    ## or `moveSpeed` rather than by hand.
    spec*: string

proc fmtNum(v: float): string =
  ## Fixed-point with three decimals, no exponent. The wire alphabet has no `e`
  ## in it for numbers, and a coordinate rendered as `1.4e-05` would be refused
  ## at the far end — silently, on a channel where the only symptom is a bot that
  ## does not move. So it is rendered here, once, in a shape that always survives.
  var neg = v < 0.0
  var a = (if neg: -v else: v)
  if a > 100000.0:
    a = 100000.0
  let whole = int(a)
  var frac = int((a - float(whole)) * 1000.0 + 0.5)
  var w = whole
  if frac >= 1000:
    frac = frac - 1000
    w = w + 1
  var f = $frac
  while f.len < 3:
    f = "0" & f
  result = (if neg and (w != 0 or frac != 0): "-" else: "") & $w & "." & f

proc idText(id: int): string =
  if id < 0: "all" else: $id

proc goTo*(id: int; x, y, z: float; reach: float = 1.0;
           sprint: bool = false; holdMs: int = 20000): BotCommand =
  ## "Bot `id`, walk to (x, y, z)." Pass `BotNavAll` for every bot.
  ##
  ## `reach` is how close counts as arrived, in metres, clamped by the host to
  ## 0.25..50. `holdMs` is how long the host keeps re-issuing this before giving
  ## up — see the note above on commands being advisory; a `holdMs` of zero would
  ## mean "say it once and let the brain overrule it", which is almost never what
  ## anyone wants.
  ##
  ## `sprint` is honoured as "move at full speed" (the host sets the mover's
  ## speed to 1.0 once, when the command is first issued) rather than by calling
  ## the game's own `BotOwner::Sprint`. Same visible effect for a bot crossing a
  ## map; considerably less of the game's machinery touched.
  var s = idText(id) & "|" & fmtNum(x) & "|" & fmtNum(y) & "|" & fmtNum(z) &
          "|" & fmtNum(reach) & "|" & (if sprint: "1" else: "0")
  var h = holdMs
  if h < 1: h = 1
  if h > 600000: h = 600000
  s = s & "|" & $h
  result = BotCommand(spec: s)

proc stop*(id: int): BotCommand =
  ## "Bot `id`, stand still." Clears any active command and calls the game's own
  ## `BotOwner::StopMove`. The brain will pick its own goal again shortly — this
  ## stops the bot, it does not pin it.
  BotCommand(spec: idText(id) & "|stop")

proc moveSpeed*(id: int; speed: float): BotCommand =
  ## "Bot `id`, move at `speed`" — 0.0..1.0, written straight into
  ## `BotMover.MoveSpeed`. Independent of any active destination.
  var s = speed
  if s < 0.0: s = 0.0
  if s > 1.0: s = 1.0
  BotCommand(spec: idText(id) & "|speed|" & fmtNum(s))

proc botNavSpecAcceptable*(s: string): bool =
  ## Whether `s` is a command string this will carry. Exposed so a mod that
  ## builds a set by hand can check it and say something useful, instead of
  ## sending it and having to infer the refusal from bots that did not move.
  if s.len > BotNavMaxSpec:
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

proc sendBotCommands*(cmds: seq[BotCommand]): Status =
  ## Publish a whole command set, replacing whatever was in force.
  ##
  ## Returns `Ok` when the request was broadcast, `ErrBadArg` when the set is too
  ## long or malformed. `Ok` means "asked", not "done": whether anything moves
  ## depends on the player having set `botNav`, on the manager being up, on the
  ## client host being in a raid, and on the bots' own brains. None of those are
  ## things this call can know, and none of them are failures worth an error —
  ## the honest answer to all of them is a bot that carries on as it was.
  ##
  ## An empty `cmds` clears the set and hands every bot back to its own brain.
  if cmds.len > BotNavMaxCommands:
    return ErrBadArg
  var spec = ""
  for c in cmds:
    if c.spec.len == 0:
      continue
    if spec.len > 0:
      spec.add ';'
    spec.add c.spec
  if not botNavSpecAcceptable(spec):
    return ErrBadArg
  result = broadcast("aowlspt.bot.nav", objOf("spec", spec))

proc sendBotTo*(id: int; x, y, z: float; reach: float = 1.0;
                sprint: bool = false; holdMs: int = 20000): Status =
  ## The one-liner: send a single bot to a point, replacing the command set.
  sendBotCommands(@[goTo(id, x, y, z, reach, sprint, holdMs)])

proc sendBotsTo*(id: int; x, y, z: float; reach: float = 1.0;
                 sprint: bool = false; holdMs: int = 20000): Status =
  ## Alias for `sendBotTo` that reads better with `BotNavAll`.
  sendBotTo(id, x, y, z, reach, sprint, holdMs)

proc stopBot*(id: int): Status =
  ## Stop one bot (or `BotNavAll`), replacing the command set.
  sendBotCommands(@[stop(id)])

proc clearBotNav*(): Status =
  ## Drop every command and hand the bots back to their own brains. Worth calling
  ## from a mod's `onUnload`, so a mod that is switched off does not leave a
  ## squad marching at a wall for the rest of the session.
  sendBotCommands(@[])

# ---------------------------------------------------------------------------
# Reading the registry back
# ---------------------------------------------------------------------------

proc splitOn(s: string; sep: char): seq[string] =
  result = @[]
  var cur = ""
  for ch in s:
    if ch == sep:
      result.add cur
      cur = ""
    else:
      cur.add ch
  result.add cur

proc numOf(s: string): float =
  ## Total, exception-free reader for the census's own fixed-point numbers. A
  ## field that does not parse reads as 0.0 rather than throwing: this decodes a
  ## report from another process, and one malformed field should cost that field,
  ## not the whole census.
  result = 0.0
  if s.len == 0: return
  var i = 0
  var neg = false
  if s[0] == '-':
    neg = true
    i = 1
  elif s[0] == '+':
    i = 1
  var v = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    v = v * 10.0 + float(ord(s[i]) - ord('0'))
    inc i
  if i < s.len and s[i] == '.':
    inc i
    var scale = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      v = v + float(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
  result = (if neg: -v else: v)

proc parseBotCensus*(census: string): seq[BotInfo] =
  ## Decode the host's registry string into rows. Exposed because a mod that has
  ## already fetched `/aowlspt/mods/clientreport` for other reasons should not
  ## have to fetch it twice.
  ##
  ## Format, per bot, `!`-separated:
  ##     id,role,difficulty,alive,x,y,z,navStatus
  ##
  ## A row with the wrong field count is skipped. The census is a state that is
  ## resent every poll, so a dropped row costs at most one poll of staleness —
  ## which is a far better outcome than refusing the whole census over one bad
  ## record.
  result = @[]
  if census.len == 0:
    return
  for rec in splitOn(census, '!'):
    if rec.len == 0:
      continue
    let f = splitOn(rec, ',')
    if f.len < 8:
      continue
    result.add BotInfo(id: int(numOf(f[0])), role: int(numOf(f[1])),
                       difficulty: int(numOf(f[2])), alive: f[3] == "1",
                       x: numOf(f[4]), y: numOf(f[5]), z: numOf(f[6]),
                       navStatus: int(numOf(f[7])))

proc botsFromEvent*(payload: string): seq[BotInfo] =
  ## Decode an `aowlspt.bot.census` payload — `{"count":<n>,"census":"..."}` —
  ## into bot rows. This is what an `onBotCensus` handler wants.
  parseBotCensus(field(payload, "census").asText(""))

proc censusCountFromEvent*(payload: string): int =
  ## How many censuses the manager has taken, out of the same payload. Zero
  ## means no client host has ever reported a registry — which is a different
  ## thing from an empty registry (a raid with no bots in it), and worth being
  ## able to tell apart before concluding the feature is broken.
  field(payload, "count").asInt(0)

proc onBotCensus*(handler: EventHandler): Status =
  ## Subscribe to the client host's bot registry. The handler is called with an
  ## `aowlspt.bot.census` payload each time a NEW census arrives — roughly every
  ## `modSyncMs` while a raid with bots is running, and not at all otherwise.
  ##
  ## Decode it with `botsFromEvent`. The handler's return value is ignored; an
  ## empty string is the convention.
  onEvent("aowlspt.bot.census", handler)
