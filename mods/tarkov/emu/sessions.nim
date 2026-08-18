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

var gBindings: seq[Binding] = @[]
var gLoaded = false

proc persist() =
  var a = arr()
  for b in gBindings:
    var o = obj()
    put(o, "s", b.session)
    put(o, "p", b.profile)
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
      gBindings.add Binding(session: s, profile: p)

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
  gBindings.add Binding(session: session, profile: profile)
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
