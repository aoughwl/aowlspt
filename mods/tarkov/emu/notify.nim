## Telling the client something happened.
##
## The client opens a notification channel at login. Everything the server
## decides on its own — a message arriving, an insurance return posted, a flea
## offer sold, a quest becoming available — has nowhere to go without it. The
## server can change the profile all it likes; the player finds out on the next
## screen that happens to reload.
##
## **There are two ways out now, and the order matters.**
##
## 1. `notifyPush` — the revision-5 host call. The backend holds the client's
##    notifier websocket and pushes the event down it, and the player sees it
##    the instant it happens.
## 2. The queue below, drained by `/client/notifier/getwebsocket`, which
##    answers immediately whether it has news or not.
##
## `deliver` tries the first and falls back to the second, and the fallback is
## not a formality: `notifyPush` answers `ErrNotFound` for any session with no
## socket open, which is every client that has not upgraded, has not finished
## logging in, or has just lost its connection. A client that never upgrades
## behaves exactly as it did before this existed.
##
## The poll used to be the *only* way, and the reason it was is worth keeping
## because it is a reason that stopped being true rather than one that was
## wrong. The backend served on a fixed pool of accept threads; a held
## connection occupied one for the whole wait, and four players idling in the
## menu would take the pool and the server would stop answering anything. The
## poller replaced that: a connection nobody is answering costs a socket and its
## buffer, the bound is 1024 sockets and 64 MiB rather than sixteen threads, and
## a held websocket became affordable. `backend/websocket.nim` is the half that
## holds it; nothing here knows a socket exists.
##
## The queue is in memory and deliberately not persisted. A notification is
## about something that already happened to the profile — the profile is the
## durable record, and a notification replayed after a restart tells the player
## about a message they read yesterday.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import ids
import sessions

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

proc notifyOrQueue*(session, payload: string): bool =
  ## The one call the rest of the emulator makes. True when it went out over
  ## the websocket, false when it went into the queue for the poll to pick up.
  ##
  ## Both are delivery. The return value is for the log line, not for a caller
  ## to branch on -- a caller that treated `false` as a failure would be
  ## treating "this player has not upgraded" as an error, and every client did
  ## that until this pass.
  ##
  ## Named for what it does rather than `deliver`, which `emu/mail` already
  ## uses for putting a message in an inbox. Two `deliver`s in one file
  ## resolved by argument count is a thing that reads correctly and is wrong the
  ## first time somebody adds an overload.
  if session.len == 0 or payload.len == 0:
    return false
  if notifyPush(session, payload) == Ok:
    return true
  push(session, payload)
  result = false

proc notifyProfile*(profileId, payload: string): int =
  ## The same, addressed by *profile* rather than by session, and answering how
  ## many sessions it reached.
  ##
  ## Everything inside the emulator that decides something happened knows the
  ## profile it happened to; only the request layer knows a session. This is the
  ## join, and it is a loop over the bound sessions rather than a reverse index
  ## because a single-player server has one of them. Zero is a normal answer:
  ## a profile nobody is logged in to has nobody to tell, and the profile itself
  ## is the durable record of what happened.
  var sessions: seq[string] = @[]
  var profiles: seq[string] = @[]
  boundSessions(sessions, profiles)
  result = 0
  for i in 0 ..< sessions.len:
    if profiles[i] == profileId:
      discard notifyOrQueue(sessions[i], payload)
      inc result

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
