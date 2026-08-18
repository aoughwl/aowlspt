## Revenge: a faction that remembers you killed one of theirs.
##
## The rule is small. Kill a bot belonging to a faction with `revengeAfterRaids`
## set, and that faction owes you a grudge for the next N raids — during which
## its bots treat you as an enemy on sight, whatever side you are playing. The
## client reports the kills at the end of a raid; the server holds the counters
## and hands them back at the start of the next one.
##
## Two departures from the original, both deliberate:
##
## **Whose counters get decremented.** Upstream decremented every profile that
## had been active in the last ten minutes, with a `TODO` saying it should be
## the profiles that were actually in the raid. There is no activity service
## here to be wrong with, so the decrement applies to exactly the profiles named
## in the request — which is what the `TODO` asked for.
##
## **Where they live.** `save`/`load`, this mod's own store, one key per
## profile. Not `dbWrite`: the database is the shared game tables, and a
## player's grudges are not a game table.
##
## The store is optional. A host without one (the simulator, for instance) gets
## an in-memory copy and a line in the log saying so, rather than a mod that
## refuses to load over a feature most of it does not need.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import factions

# profile id -> the raw JSON of {"faction": raidsLeft}. Held as text so the
# in-memory path and the persisted path are the same shape and cannot drift.
var gMemProfiles: seq[string] = @[]
var gMemData: seq[string] = @[]
var gPersistent = false

const KeyPrefix = "revenge."

proc initRevenge*() =
  gPersistent = storeReady()
  if not gPersistent:
    warn "morebots: this host has no persistent store; revenge counters will " &
         "be forgotten when the server stops"

proc memIndex(profileId: string): int =
  result = -1
  for i in 0 ..< gMemProfiles.len:
    if gMemProfiles[i] == profileId:
      return i

proc readCounters(profileId: string): string =
  if gPersistent:
    let s = load(KeyPrefix & profileId)
    if s.ok and s.raw.len > 0:
      return s.raw
    return "{}"
  let i = memIndex(profileId)
  if i >= 0:
    return gMemData[i]
  result = "{}"

proc writeCounters(profileId, json1: string) =
  if gPersistent:
    discard save(KeyPrefix & profileId, json1)
    return
  let i = memIndex(profileId)
  if i >= 0:
    gMemData[i] = json1
  else:
    gMemProfiles.add profileId
    gMemData.add json1

proc knownProfiles(): seq[string] =
  if gPersistent:
    result = @[]
    let all = savedKeys(KeyPrefix)
    for k in all:
      if k.len > KeyPrefix.len:
        result.add k.substr(KeyPrefix.len)
    return
  result = gMemProfiles

proc owedFactions*(profileId: string): seq[string] =
  ## The factions with raids still to run, for this profile.
  result = @[]
  let doc = whole(readCounters(profileId))
  let names = keys(doc)
  for n in names:
    if child(doc, n).asInt(0) > 0:
      result.add n

proc revengesJson*(): string =
  ## `/morebotsapi/getrevenges`: `{"<profileId>": ["blackdiv", ...]}`.
  var o = obj()
  let profiles = knownProfiles()
  for p in profiles:
    var a = arr()
    let owed = owedFactions(p)
    for f in owed:
      a.add f
    put(o, p, a)
  result = done(o).text

proc decrementFor(profileId: string) =
  ## One raid gone by. Counters at zero are kept rather than removed, so
  ## `getrevenges` and the log both keep showing a faction the player has
  ## finished paying off — which reads much better than an entry that silently
  ## vanishes.
  let cur = readCounters(profileId)
  let doc = whole(cur)
  let names = keys(doc)
  if names.len == 0:
    return
  var o = obj()
  for n in names:
    var v = child(doc, n).asInt(0)
    if v > 0:
      dec v
    put(o, n, v)
  writeCounters(profileId, done(o).text)

proc armFor(profileId: string; factionNames: seq[string]) =
  let cur = readCounters(profileId)
  let doc = whole(cur)
  var o = obj()
  let existing = keys(doc)
  var written: seq[string] = @[]
  for n in existing:
    var v = child(doc, n).asInt(0)
    for f in factionNames:
      if f == n:
        v = revengeAmountOf(f)
        written.add f
    put(o, n, v)
  for f in factionNames:
    var already = false
    for w in written:
      if w == f:
        already = true
    if already:
      continue
    let amount = revengeAmountOf(f)
    if amount <= 0:
      warn "morebots: revenge asked for unknown faction '" & f & "'"
      continue
    put(o, f, amount)
  writeCounters(profileId, done(o).text)

proc updateRevenge*(body: string): int =
  ## `/morebotsapi/updaterevenge`. Body:
  ##
  ##     {"RevengeUpdate": {"<profileId>": ["blackdiv", ...]}}
  ##
  ## Decrement first, then arm — so a faction the player provoked *this* raid
  ## comes out of it at its full count rather than one short. Getting that order
  ## backwards is a grudge that quietly lasts one raid less than advertised.
  result = 0
  let upd = field(body, "RevengeUpdate")
  if not upd.found:
    return
  let profiles = keys(upd)
  for p in profiles:
    decrementFor(p)
    var names: seq[string] = @[]
    let listed = each(child(upd, p))
    for f in listed:
      let n = f.asText("")
      if n.len > 0:
        names.add n
    if names.len > 0:
      armFor(p, names)
    inc result
