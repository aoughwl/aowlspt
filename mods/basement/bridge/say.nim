## bridge/say.nim -- PLAYING A REPLY, ONE SEGMENT AT A TIME.
##
## A single NPC reply arrives as SEVERAL `say` events, one per sentence, with
## an increasing `segmentIdx` and the last carrying `final:true`
## (CLIENT-CONTRACT section 7). They are played in `seq` ORDER and NOTHING
## WAITS FOR `final` -- waiting for it throws away the whole point and adds
## seconds of silence to every line.
##
## WHAT THIS CANNOT DO TODAY, SAID PLAINLY RATHER THAN PRETENDED
## -------------------------------------------------------------
## The contract asks for one playback queue per `personId`, drained
## "back-to-back with no gap". `aowlspt.host::play_wav` is FIRE AND FORGET:
## it answers `{"ok":true,...}` the moment winmm accepts the file and there is
## NO completion signal and NO duration anywhere in its answer (measured: read
## `hnPlayWavVerb` in `host/Aowlspt.Host.Il2Cpp/hostnet.nim` -- the answer is
## `ok`, `spatial:false`, `volumeIgnored:true`, `note`, `played`). So a client
## cannot know when a segment ENDS, and therefore cannot start the next one at
## the right moment.
##
## The queue below is therefore an ORDERING structure, not a pacing one: it
## holds the segments of an utterance and drains them in `seq` order on the
## bridge tick, and it does NOT space them out, because spacing them on a guess
## would be worse than overlapping honestly. This is stated in the log once, at
## the first segment played, so nobody has to read this file to find it out.
##
## `wav == ""` is TTS off/missing/failed. Then the `text` is all there is: it
## is logged as a subtitle. It is never replaced by a beep and never dropped.

import aowlspt
import aowlspt/json
import core

type
  Segment = object
    personId: string
    seqNo: int
    segIdx: int
    wav: string
    text: string
    final: bool
    ackWanted: bool

var gQueue: seq[Segment] = @[]
var gHead = 0
var gSegments = 0
var gSubtitles = 0
var gFlushes = 0
var gLastPerson = ""
var gLastText = ""

proc segments*(): int = gSegments
proc subtitles*(): int = gSubtitles
proc flushes*(): int = gFlushes
proc queued*(): int = gQueue.len - gHead
proc lastLine*(): string = gLastText

proc enqueue*(personId: string; seqNo, segIdx: int; wav, text: string;
              final, ackWanted: bool) =
  ## A NEW utterance for the same person (`segmentIdx == 0`) FLUSHES whatever
  ## of the old one has not played: the world moved on, and playing the tail of
  ## a superseded line is the confusing behaviour the contract calls out.
  if segIdx == 0 and personId.len > 0:
    var i = gHead
    var dropped = 0
    while i < gQueue.len:
      if gQueue[i].personId == personId:
        # Marked spent rather than removed: a `seq` deletion in the middle
        # would reorder everything behind it, and order is the one property
        # this queue exists to keep.
        gQueue[i].wav = ""
        gQueue[i].text = ""
        gQueue[i].personId = ""
        dropped = dropped + 1
      i = i + 1
    if dropped > 0:
      gFlushes = gFlushes + 1
      info "basement say: flushed " & $dropped & " unplayed segment(s) for " &
           personId & " -- a new utterance (segmentIdx 0) superseded them."
  gQueue.add Segment(personId: personId, seqNo: seqNo, segIdx: segIdx,
                     wav: wav, text: text, final: final, ackWanted: ackWanted)

proc playOne(s: Segment) =
  gSegments = gSegments + 1
  gLastPerson = s.personId
  gLastText = s.text
  if s.wav.len == 0:
    gSubtitles = gSubtitles + 1
    info "basement say [" & s.personId & " seg " & $s.segIdx & "]: " & s.text &
         "  (no wav on this segment -- TTS is off, missing or failed, so the " &
         "text IS the line; nothing was substituted for it)"
    if s.ackWanted:
      ackDirective(s.seqNo, true, "shown as a subtitle; the segment carried " &
                   "no wav path")
    return
  var why = ""
  if playWav(s.wav, why):
    if not saidOnce("say-pacing"):
      info "basement say: segments are played in seq order the moment they " &
           "arrive. `aowlspt.host::play_wav` reports no completion and no " &
           "duration, so this client CANNOT space them by sentence length; " &
           "two long segments can overlap. That is a known limit of the verb, " &
           "not a queue bug."
    if s.ackWanted:
      ackDirective(s.seqNo, true, "play_wav accepted " & s.wav)
  else:
    info "basement say [" & s.personId & " seg " & $s.segIdx & "]: " & s.text &
         "  (subtitle only -- " & why & ")"
    if s.ackWanted:
      ackDirective(s.seqNo, false, "play_wav refused: " & why)

proc drain*() =
  ## Called from the bridge tick. Drains everything pending, in arrival order,
  ## which is `seq` order because `/events` returns oldest-first and the link
  ## dispatches a batch in the order it was given.
  while gHead < gQueue.len:
    let s = gQueue[gHead]
    gHead = gHead + 1
    if s.personId.len == 0 and s.wav.len == 0 and s.text.len == 0:
      continue
    playOne(s)
  if gHead > 0 and gHead == gQueue.len:
    gQueue = @[]
    gHead = 0
