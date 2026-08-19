## Where the player is standing, and what the world looked like before this
## mod moved anything.
##
## Two facts live here and they have very different failure modes.
##
## **The position** is the game state this mod invents. Losing it puts the
## player back at the starting zone with no explanation, which is annoying.
##
## **The baseline** is what `Locked` said on every map *before this mod ever
## wrote one*. Losing that is not annoying, it is unrecoverable by the player:
## uninstall the mod and every map it had locked stays locked, in a database
## that persists, with nothing anywhere saying why. So the baseline is captured
## exactly once — the first time a map is seen with no baseline recorded — and
## every later read of `Locked` is ignored, because by then the value being read
## is this mod's own writing.
##
## The same record is what crosses a hot reload. `stateSave` runs just before
## the library is freed and `stateLoad` on the next incarnation, and both halves
## are `encode`/`decode` below — one text format, so a rebuild mid-session and a
## server restart recover the same way and there is only one thing to get right.
##
## Nothing here talks to a host: `tests/pttguard` drives it directly.

import aowlspt/json

type
  Baseline* = object
    key*: string
    locked*: bool

  State* = object
    position*: string        ## the map key the player is standing on
    moves*: int              ## how many times the position has changed
    baseline*: seq[Baseline] ## `Locked` as it was before this mod wrote any
    pendingProfile*: string  ## the raid being configured, if any
    pendingLocation*: string
    pendingSide*: string
    lastSession*: string     ## the last session id seen on one of our routes

proc newState*(position: string): State =
  result = State(position: position, moves: 0, baseline: @[],
                 pendingProfile: "", pendingLocation: "", pendingSide: "",
                 lastSession: "")

proc baselineIndex*(s: State; key: string): int =
  result = -1
  for i in 0 ..< s.baseline.len:
    if s.baseline[i].key == key:
      return i

proc knowsBaseline*(s: State; key: string): bool = baselineIndex(s, key) >= 0

proc rememberBaseline*(s: var State; key: string; locked: bool): bool =
  ## Record what `Locked` said on a map this mod has not touched yet. False
  ## when a baseline is already held, and the existing one is kept — that is
  ## the whole point of the record and the one line that must not be "helpful".
  if key.len == 0:
    return false
  if knowsBaseline(s, key):
    return false
  s.baseline.add Baseline(key: key, locked: locked)
  result = true

proc baselineLocked*(s: State; key: string; known: var bool): bool =
  ## What `Locked` was before this mod. `known` says whether the answer means
  ## anything; the return value alone cannot, because `false` is both "it was
  ## unlocked" and "no idea".
  let at = baselineIndex(s, key)
  known = at >= 0
  if not known:
    return false
  result = s.baseline[at].locked

proc moveTo*(s: var State; key: string): bool =
  ## False when the player is already there, so the caller can tell a real move
  ## from a raid that ended where it started.
  if key.len == 0 or key == s.position:
    return false
  s.position = key
  inc s.moves
  result = true

proc beginRaid*(s: var State; profile, location, side: string) =
  s.pendingProfile = profile
  s.pendingLocation = location
  s.pendingSide = side

proc clearRaid*(s: var State) =
  s.pendingProfile = ""
  s.pendingLocation = ""
  s.pendingSide = ""

proc isScav*(side: string): bool =
  ## The client sends `Pmc` or `Savage`; a raid configured with neither is
  ## treated as a PMC raid, because that is the one that moves the player and
  ## an unrecognised side must not silently disable the mod.
  result = side == "Savage" or side == "savage" or side == "Scav" or
           side == "scav"

proc raidEndMoves*(s: State; profile: string; scavRaidsMove: bool;
                   toKey: var string): bool =
  ## Does this raid ending move the player, and where to?
  ##
  ## The pair is the whole mechanism: `tarkov.raid.configured` names the profile
  ## and the location, `tarkov.raid.ended` names only the profile. Matching the
  ## two on the profile id is what makes the location trustworthy — a raid ended
  ## for a profile that is not the one that was configured is somebody else's,
  ## and answering it would move this player to a map they never loaded.
  toKey = ""
  if s.pendingLocation.len == 0:
    return false
  if profile.len > 0 and s.pendingProfile.len > 0 and
     profile != s.pendingProfile:
    return false
  if isScav(s.pendingSide) and not scavRaidsMove:
    return false
  toKey = s.pendingLocation
  result = true

proc encode*(s: State): string =
  ## One text format for the store and for a hot reload.
  var b = "{\"position\":" & quoted(s.position) &
          ",\"moves\":" & $s.moves &
          ",\"pendingProfile\":" & quoted(s.pendingProfile) &
          ",\"pendingLocation\":" & quoted(s.pendingLocation) &
          ",\"pendingSide\":" & quoted(s.pendingSide) &
          ",\"lastSession\":" & quoted(s.lastSession) &
          ",\"baseline\":["
  for i in 0 ..< s.baseline.len:
    if i > 0:
      b.add ","
    b.add "{\"key\":" & quoted(s.baseline[i].key) & ",\"locked\":" &
          (if s.baseline[i].locked: "true" else: "false") & "}"
  b.add "]}"
  result = b

proc decode*(text: string; fallbackPosition: string): State =
  ## The inverse. A document that is not an object gives the fallback position
  ## and an **empty** baseline, which the caller must treat as "nothing is
  ## known" rather than as "nothing was locked" — those differ by the whole
  ## uninstall path.
  result = newState(fallbackPosition)
  if text.len < 2:
    return
  let d = whole(text)
  if not isObject(d):
    return
  let pos = child(d, "position").asText("")
  if pos.len > 0:
    result.position = pos
  result.moves = child(d, "moves").asInt(0)
  result.pendingProfile = child(d, "pendingProfile").asText("")
  result.pendingLocation = child(d, "pendingLocation").asText("")
  result.pendingSide = child(d, "pendingSide").asText("")
  result.lastSession = child(d, "lastSession").asText("")
  let arrRaw = raw(child(d, "baseline"))
  if arrRaw.len >= 2:
    let list = whole(arrRaw)
    if isArray(list):
      let items = each(list)
      for it in items:
        let k = child(it, "key").asText("")
        if k.len > 0:
          result.baseline.add Baseline(key: k,
                                       locked: child(it, "locked").asBool(false))
