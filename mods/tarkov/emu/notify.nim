## Telling the client something happened.
##
## The client opens a notification channel at login and polls it for the rest of
## the session. Everything the server decides on its own — a message arriving, an
## insurance return posted, a flea offer sold, a quest becoming available — has
## nowhere to go without it. The server can change the profile all it likes; the
## player finds out on the next screen that happens to reload.
##
## So: a queue per session, drained by the poll.
##
## **The poll answers immediately, empty or not.** Long-polling is what the real
## server does and it is the wrong shape here: the backend serves on a fixed pool
## of accept threads, and a held connection occupies one of them for the whole
## wait. Four players idling in the menu would take the whole pool and the server
## would stop answering anything. An immediate empty answer costs a request every
## few seconds and cannot deadlock.
##
## The queue is in memory and deliberately not persisted. A notification is about
## something that already happened to the profile — the profile is the durable
## record, and a notification replayed after a restart tells the player about a
## message they read yesterday.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids

const
  ## Past this, the oldest go. A client that stopped polling must not be able to
  ## grow the server's memory without bound, and a player who has been away long
  ## enough to overflow this will see the state rather than the news.
  MaxQueued* = 64

type
  Note = object
    session: string
    payload: string

var gNotes: seq[Note] = @[]

proc noteCount*(): int = gNotes.len

proc push*(session, payload: string) =
  ## Queues one notification for one session.
  if session.len == 0 or payload.len == 0:
    return
  if gNotes.len >= MaxQueued:
    # Drop the oldest, not the newest: the newest is the one the player has not
    # heard about yet.
    var keep: seq[Note] = @[]
    for i in 1 ..< gNotes.len:
      keep.add gNotes[i]
    gNotes = keep
  gNotes.add Note(session: session, payload: payload)

proc take*(session: string): string =
  ## The next notification for this session, or "" when there is none. One at a
  ## time, because the client's channel delivers one event per poll and batching
  ## them into an array is a shape it does not read.
  result = ""
  var at = -1
  for i in 0 ..< gNotes.len:
    if gNotes[i].session == session:
      at = i
      break
  if at < 0:
    return
  result = gNotes[at].payload
  var keep: seq[Note] = @[]
  for i in 0 ..< gNotes.len:
    if i != at:
      keep.add gNotes[i]
  gNotes = keep

proc dropSession*(session: string) =
  var keep: seq[Note] = @[]
  for n in gNotes:
    if n.session != session:
      keep.add n
  gNotes = keep

# ---------------------------------------------------------------------------
# The shapes the client reads
# ---------------------------------------------------------------------------
#
# Each is one event with a `type` the client dispatches on. A type it does not
# know is ignored rather than fatal, which is why an unrecognised notification
# is a missed message and not a broken session.

proc ping*(): string =
  ## What a poll with nothing to say answers. Not an empty body: the client
  ## treats a malformed answer as a channel failure and reopens it, which turns
  ## an idle menu into a reconnect loop.
  var o = obj()
  put(o, "type", "ping")
  put(o, "eventId", "ping")
  result = done(o).text

proc newMessageNote*(dialogId, messageId: string; kind: int;
                     nowSeconds: int): string =
  ## A message arrived. The client opens the inbox badge from this.
  var m = obj()
  put(m, "_id", messageId)
  put(m, "uid", dialogId)
  put(m, "type", kind)
  put(m, "dt", nowSeconds)
  put(m, "hasRewards", true)
  var o = obj()
  put(o, "type", "new_message")
  put(o, "eventId", newId())
  put(o, "dialogId", dialogId)
  put(o, "message", m)
  result = done(o).text

proc traderSupplyNote*(traderId: string; nextResupply: int): string =
  ## A trader restocked.
  var o = obj()
  put(o, "type", "TraderSupply")
  put(o, "eventId", newId())
  put(o, "data", objOf("traderId", traderId))
  put(o, "nextResupply", nextResupply)
  result = done(o).text

proc questNote*(questId, state: string): string =
  ## A quest changed state -- became available, or failed on a timer.
  var o = obj()
  put(o, "type", "QuestStatus")
  put(o, "eventId", newId())
  put(o, "qid", questId)
  put(o, "status", state)
  result = done(o).text
