## Which profile a session id is playing.
##
## The client carries one `PHPSESSID` cookie for the whole run and the server has
## to map it to a profile. The map is persisted, not just held in memory, for a
## reason that is easy to miss: the client does not re-select a profile after the
## server restarts. It keeps sending the same session id, and a server that
## forgot the mapping answers every request with "no profile" while the client
## sits in a menu it cannot leave.
##
## Kept as one stored document rather than a key per session, because it is read
## on every single request and a handful of entries is not worth a file each.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json

const StoreKey = "sessions"

type
  Binding = object
    session: string
    profile: string
    # Where the session is currently in a raid, or "" when it is not.
    #
    # Held here, and persisted with the rest of the binding, because the raid
    # result the client posts at the end **does not name the map**. Its top
    # level is `{serverId, results, lostInsuredItems, transferItems,
    # locationTransit}` and `serverId` is of the form
    # `TUTORIAL_1891947_20_08_2026_01_20_33` -- a mode and an account and a
    # timestamp, no location. The only place the map is ever sent is on the way
    # in, in `match/local/start` and `raid/configuration`.
    #
    # So it has to be remembered across the raid, and it has to survive a
    # restart for the same reason the profile binding does: the client does not
    # re-send it, and a server that forgets answers the end of the raid with
    # the wrong map. Every `Location`-qualified kill condition then silently
    # stops counting -- silently, because a quest that does not progress looks
    # exactly like a quest the player has not done.
    raidLocation: string
    raidMode: string

var gBindings: seq[Binding] = @[]
var gLoaded = false

proc persist() =
  var a = arr()
  for b in gBindings:
    var o = obj()
    put(o, "s", b.session)
    put(o, "p", b.profile)
    if b.raidLocation.len > 0: put(o, "rl", b.raidLocation)
    if b.raidMode.len > 0: put(o, "rm", b.raidMode)
    a.add o
  if save(StoreKey, done(a)) != Ok:
    warn "could not persist the session map: " & lastError()

proc ensureLoaded() =
  if gLoaded:
    return
  gLoaded = true
  let stored = load(StoreKey)
  if not stored.ok:
    return
  let list = whole(stored.raw)
  let entries = each(list)
  for e in entries:
    let s = e.field("s").asText("")
    let p = e.field("p").asText("")
    if s.len > 0 and p.len > 0:
      gBindings.add Binding(session: s, profile: p,
                            raidLocation: e.field("rl").asText(""),
                            raidMode: e.field("rm").asText(""))

proc profileFor*(session: string): string =
  ## The profile bound to this session, or "" when there is none.
  ensureLoaded()
  for b in gBindings:
    if b.session == session:
      return b.profile
  result = ""

proc bindSession*(session, profile: string) =
  ## Binds, or rebinds -- selecting a different profile on the same session is
  ## the ordinary case, not a conflict.
  ensureLoaded()
  for i in 0 ..< gBindings.len:
    if gBindings[i].session == session:
      gBindings[i].profile = profile
      persist()
      return
  gBindings.add Binding(session: session, profile: profile,
                        raidLocation: "", raidMode: "")
  persist()

proc unbind*(session: string) =
  ensureLoaded()
  var keep: seq[Binding] = @[]
  for b in gBindings:
    if b.session != session:
      keep.add b
  gBindings = keep
  persist()

proc sessionCount*(): int =
  ensureLoaded()
  result = gBindings.len

proc boundSessions*(sessions, profiles: var seq[string]) =
  ## Every session and the profile it is playing, for a sweep that has to visit
  ## each of them. Two parallel sequences rather than the internal record type,
  ## so nothing outside this module depends on how a binding is stored.
  ensureLoaded()
  sessions = @[]
  profiles = @[]
  for b in gBindings:
    sessions.add b.session
    profiles.add b.profile

proc enterRaid*(session, location, mode: string) =
  ## Remembers the map a session has gone into a raid on.
  ##
  ## A session with no binding is ignored rather than given one: a raid started
  ## by a session that never selected a profile is not a state this server can
  ## finish, and inventing a binding here would hide that rather than fix it.
  ensureLoaded()
  for i in 0 ..< gBindings.len:
    if gBindings[i].session == session:
      gBindings[i].raidLocation = location
      gBindings[i].raidMode = mode
      persist()
      return

proc leaveRaid*(session: string) =
  ## Clears the raid state. Called once the result has been applied, not when
  ## it arrives -- a raid whose result failed to save is still a raid in
  ## progress, and forgetting the map would make the retry worse than the
  ## failure.
  ensureLoaded()
  for i in 0 ..< gBindings.len:
    if gBindings[i].session == session:
      if gBindings[i].raidLocation.len == 0 and gBindings[i].raidMode.len == 0:
        return
      gBindings[i].raidLocation = ""
      gBindings[i].raidMode = ""
      persist()
      return

proc raidLocationFor*(session: string): string =
  ## The map this session is in a raid on, or "" if it is not in one.
  ensureLoaded()
  for b in gBindings:
    if b.session == session:
      return b.raidLocation
  result = ""

proc raidModeFor*(session: string): string =
  ensureLoaded()
  for b in gBindings:
    if b.session == session:
      return b.raidMode
  result = ""

proc inRaid*(session: string): bool =
  result = raidLocationFor(session).len > 0
