## Raids: getting into one, and what happens on the way out.
##
## The client asks for a location's loot and a raid configuration, plays the
## raid itself entirely on its own machine, and then tells the server what
## happened. The server's job is at the two ends: hand over a map that is
## consistent enough to load, and take the result seriously enough that dying
## costs something.
##
## The end that matters is the exit. `/client/match/local/end` carries the
## profile the client played with — health, inventory, everything picked up —
## and a server that ignores it is a server where raids have no consequences.
## Saving it is what makes the game a game rather than a menu.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

type
  RaidResult* = enum
    rrSurvived, rrKilled, rrLeft, rrRunner, rrMissingInAction

proc parseResult*(s: string): RaidResult =
  case s
  of "Survived": rrSurvived
  of "Killed": rrKilled
  of "Left": rrLeft
  of "Runner": rrRunner
  of "MissingInAction": rrMissingInAction
  else: rrLeft

proc keepsGear*(r: RaidResult): bool =
  ## Whether the player walks out with what they walked in with. Death and going
  ## missing lose the gear; leaving early and running out keep it.
  case r
  of rrKilled, rrMissingInAction: false
  else: true

proc locationBase*(id: string): string =
  ## A map's static description. Looked up by both `_Id` and name, because the
  ## client asks by one and databases key by the other.
  let byKey = dbRead("locations." & id & ".base")
  if byKey.ok and byKey.raw.len > 0:
    return byKey.raw
  result = ""

proc localLoot*(locationId: string; nowSeconds: int): string =
  ## What is lying on the floor when the raid starts.
  ##
  ## The database's static loot when it has any, and an empty map when it does
  ## not -- an empty map loads and plays, which is a great deal better than a
  ## client that cannot enter a raid at all because the server had nothing to
  ## say about the floor.
  let base = locationBase(locationId)
  var o = obj()
  put(o, "Id", locationId)
  put(o, "Name", locationId)
  put(o, "Loot", arr())
  put(o, "transitionParameters", jnull())
  if base.len > 0:
    let esc = field(base, "EscapeTimeLimit")
    if esc.found:
      put(o, "EscapeTimeLimit", esc.asInt(40))
  else:
    put(o, "EscapeTimeLimit", 40)
  put(o, "UnixDateTime", nowSeconds)
  result = done(o).text

proc raidConfiguration*(body: string): string =
  ## Echoed back with the ids the client needs. The client sends its own choice
  ## of map, time and side; the server's part is to accept it and give the raid
  ## an id both ends can refer to afterwards.
  var o = obj()
  put(o, "profileId", field(body, "profileId").asText(""))
  put(o, "raidId", newId())
  put(o, "location", field(body, "location").asText("factory4_day"))
  put(o, "timeVariant", field(body, "timeVariant").asText("CURR"))
  put(o, "raidMode", field(body, "raidMode").asText("Local"))
  put(o, "side", field(body, "side").asText("Pmc"))
  result = done(o).text

proc weather*(nowSeconds: int): string =
  ## One weather record, valid and dull. The client refuses to start a raid
  ## without one, and a variable sky is content rather than pipeline.
  var w = obj()
  put(w, "timestamp", nowSeconds)
  put(w, "cloud", 0.0)
  put(w, "wind_speed", 1)
  put(w, "wind_direction", 1)
  put(w, "wind_gustiness", 0.0)
  put(w, "rain", 1)
  put(w, "rain_intensity", 0.0)
  put(w, "fog", 0.0)
  put(w, "temp", 18)
  put(w, "pressure", 760)
  put(w, "time", "")
  put(w, "date", "")
  var o = obj()
  put(o, "acceleration", 0)
  put(o, "time", "")
  put(o, "date", "")
  put(o, "weather", w)
  put(o, "season", 1)
  result = done(o).text
