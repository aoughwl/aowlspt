## What a trader actually says.
##
## `traders.<id>.dialogue` is a map of situation -> list of locale ids, and it
## is real data in the dump: Prapor has seven lists, Therapist seven, Fence one
## and the BTR driver one. Every id in them resolves in `locales.global.<lang>`
## to a line BSG wrote for that trader, and several of those lines carry
## `{location}`, `{date}` and `{time}` placeholders.
##
## Nothing read any of it. `emu/insurance` posted the same hardcoded English
## sentence for every trader and every outcome, which is the one thing a player
## cannot get from the real game: Prapor says "my dogs went to Customs", the
## Therapist says "my colleagues are working on your insurance situation", and
## the difference is most of the character either of them has.
##
## ## Three rules this module exists to keep
##
## **Nothing is invented.** A trader with no list for a situation, a locale id
## that resolves to nothing, or a line whose placeholders cannot all be filled
## produces `ok: false` and the caller falls back to what it said before. An
## empty message and a message reading "lost somewhere on {location}" are both
## worse than a plain sentence, and both were reachable from a naive version of
## this.
##
## **The choice is reproducible.** Traders pick at random from a list of five,
## and the pick here is `emu/rand` seeded from text the *store* holds -- the
## profile, the trader, the situation and the second the raid ended. So a
## delivery that fails to save and is retried says the same thing the second
## time, and a test can predict the line. There is no global entropy anywhere in
## this emulator and this does not add any; `emu/ids` has the long form of why.
##
## **The language is the client's, not the server's.** The emulator serves
## `/client/locale/<lang>` with whatever the client asks for, so resolving a
## line into English once and storing the English is wrong for everyone playing
## in another language -- and the message is stored, so it is wrong forever
## rather than for one request. The language the client last asked for is
## remembered per profile and the line is resolved against it at the moment it
## is sent, falling back to English exactly the way `templates.locale` does.
##
## The alternative -- put the locale id in the message's `templateId` and let
## the client resolve it -- is what BSG's own server does, and it is not done
## here on purpose: the client fills the placeholders from a `systemData` shape
## this project has no dump of, and a guess at it renders as literal `{date}` in
## the player's inbox. Substituting server-side is the half that can be
## verified.

import std/strutils
import aowlspt
import aowlspt/server
import aowlspt/json
import store
import rand
import raid

type
  Spoken* = object
    ## A resolved line. `ok` is false for every "the data does not say", and a
    ## caller that gets one must use its own wording rather than send `text`.
    text*: string
    id*: string   ## the locale id it came from, for logs
    ok*: bool

# ---------------------------------------------------------------------------
# Dates, written out
# ---------------------------------------------------------------------------
#
# There is no date formatting anywhere else in this emulator and no `std/times`
# in it either. `{date}` and `{time}` are the only reason one is needed, so it
# is here, it is UTC, and it is pure arithmetic that `selfCheckDialogue` pins.

proc civilFromDays*(days: int; year, month, day: var int) =
  ## Howard Hinnant's `civil_from_days`: days since 1970-01-01 to a calendar
  ## date, proleptic Gregorian, correct for negative days as well.
  let z = days + 719468
  var era = 0
  if z >= 0:
    era = z div 146097
  else:
    era = (z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  var m = mp + 3
  if mp >= 10:
    m = mp - 9
  var y = yoe + era * 400
  if m <= 2:
    y = y + 1
  year = y
  month = m
  day = d

proc twoDigits(n: int): string =
  if n < 10:
    result = "0" & $n
  else:
    result = $n

proc floorDivMod(a, b: int; q, r: var int) =
  ## Floor division, so a timestamp before the epoch does not produce a
  ## negative time of day. Nothing in this server produces one, and the
  ## arithmetic being right anyway is cheaper than the comment explaining why
  ## it cannot happen.
  q = a div b
  r = a - q * b
  if r < 0:
    q = q - 1
    r = r + b

proc dateText*(unixSeconds: int): string =
  ## `dd.mm.yyyy`, which is the form the game's own interface uses.
  var days = 0
  var rest = 0
  floorDivMod(unixSeconds, 86400, days, rest)
  var y = 0
  var m = 0
  var d = 0
  civilFromDays(days, y, m, d)
  result = twoDigits(d) & "." & twoDigits(m) & "." & $y

proc timeText*(unixSeconds: int): string =
  ## `hh:mm`, UTC. Seconds are left off: the line reads "insured on {date} at
  ## {time}" and a player does not care which second it was.
  var days = 0
  var rest = 0
  floorDivMod(unixSeconds, 86400, days, rest)
  result = twoDigits(rest div 3600) & ":" & twoDigits((rest mod 3600) div 60)

# ---------------------------------------------------------------------------
# Placeholders
# ---------------------------------------------------------------------------

proc substitute*(line, location, date, time: string; complete: var bool): string =
  ## Fills `{location}`, `{date}` and `{time}`.
  ##
  ## `complete` comes back false when any placeholder could not be filled --
  ## one this server does not know the name of, or one whose value is empty.
  ## The placeholder is copied through as written in that case so the caller can
  ## log what it was, but a false `complete` means the line must not be shown:
  ## "lost somewhere on {location}" is the sort of thing that makes a player
  ## file a bug against the game rather than against this.
  ##
  ## A `{` with no `}` after it is not a placeholder and is copied through; the
  ## data has none, and treating a stray brace as a failure would reject a line
  ## over punctuation.
  complete = true
  result = ""
  var i = 0
  while i < line.len:
    if line[i] != '{':
      result.add line[i]
      inc i
      continue
    var close = -1
    var k = i + 1
    while k < line.len:
      if line[k] == '}':
        close = k
        break
      inc k
    if close < 0:
      result.add line[i]
      inc i
      continue
    let name = line.substr(i + 1, close - 1)
    var value = ""
    case name
    of "location": value = location
    of "date": value = date
    of "time": value = time
    else: value = ""
    if value.len == 0:
      complete = false
      result.add line.substr(i, close)
    else:
      result.add value
    i = close + 1

# ---------------------------------------------------------------------------
# Choosing a line
# ---------------------------------------------------------------------------

proc pickLine*(seed: string; count: int): int =
  ## Which of `count` lines, from text. -1 when there is nothing to choose
  ## from, so a caller cannot index an empty list and get element zero of
  ## nothing.
  if count <= 0:
    return -1
  if count == 1:
    return 0
  var r = seededRng(seed)
  result = nextInt(r, count)

# ---------------------------------------------------------------------------
# The database side
# ---------------------------------------------------------------------------

proc safeLanguage*(language: string): string =
  ## A language as it may be spliced into a dotted database path. Letters,
  ## digits, `-` and `_` only: the language arrives from the client's own URL,
  ## and a dot in it would read a different subtree of the database than the
  ## one asked for.
  if language.len == 0 or language.len > 16:
    return "en"
  for ch in language:
    let okChar = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                 (ch >= '0' and ch <= '9') or ch == '-' or ch == '_'
    if not okChar:
      return "en"
  result = language

proc localeText*(language, id: string): string =
  ## One locale entry, in the language asked for and otherwise in English --
  ## the same fallback `templates.locale` serves whole tables with, so a line
  ## cannot go missing in a language whose table is partial.
  if id.len == 0:
    return ""
  let want = dbRead("locales.global." & safeLanguage(language) & "." & id)
  if want.ok and want.raw.len > 0:
    let t = whole(want.raw).asText("")
    if t.len > 0:
      return t
  let en = dbRead("locales.global.en." & id)
  if en.ok and en.raw.len > 0:
    return whole(en.raw).asText("")
  result = ""

proc dialogueLines*(traderId, key: string): seq[string] =
  ## The locale ids a trader has for one situation, in the order the database
  ## lists them.
  result = @[]
  if traderId.len == 0 or key.len == 0:
    return
  let v = dbRead("traders." & traderId & ".dialogue." & key)
  if not v.ok or v.raw.len == 0:
    return
  let list = parseArray(v.raw)
  if not list.ok:
    return
  for i in 0 ..< list.len:
    let id = whole(list.items[i]).asText("")
    if id.len > 0:
      result.add id

proc locationName*(language, location: string): string =
  ## A map as the player names it: `bigmap` -> `Customs`.
  ##
  ## `locations.<id>.base.Name` is a locale id in the real database, so it is
  ## resolved; when it does not resolve it is already English enough to show
  ## ("Streets of Tarkov" has no entry of its own). A location the database
  ## does not carry comes back as the client spelled it rather than as nothing,
  ## because an empty `{location}` rejects the whole line.
  ##
  ## The lower-cased retry is for the two spellings the client uses: the raid
  ## result says `RezervBase` where the database key is `rezervbase`.
  if location.len == 0:
    return ""
  # The lower-cased retry handled `RezervBase` -> `rezervbase` and nothing
  # else: the client's `Woods` is keyed `bigmap`, `Streets of Tarkov` is
  # `tarkovstreets`, and lower-casing reaches neither. `canonicalLocation`
  # (emu/raid) is the ONE resolver and covers all of them; the lower-cased
  # try is kept only as a last resort for an id the index has not indexed.
  var name = whole(dbRead("locations." & canonicalLocation(location) &
                          ".base.Name").raw).asText("")
  if name.len == 0:
    name = whole(dbRead("locations." & toLowerAscii(location) &
                        ".base.Name").raw).asText("")
  if name.len == 0:
    return location
  let localised = localeText(language, name)
  if localised.len > 0:
    return localised
  result = name

proc say*(traderId, key, language, seed, location: string;
          atSeconds: int): Spoken =
  ## One line from a trader, chosen reproducibly and fully filled in.
  ##
  ## The candidates are walked in a rotation starting at the chosen index, and
  ## the first one that both resolves in the locale *and* has every placeholder
  ## filled is the answer. That rotation is why a line carrying `{date}` does
  ## not cost the whole message on a queue entry written before this server
  ## recorded raid times: the pick moves on to a line that does not need one.
  ## It is still deterministic -- same seed, same database, same line.
  result = Spoken(text: "", id: "", ok: false)
  let ids = dialogueLines(traderId, key)
  let start = pickLine(seed, ids.len)
  if start < 0:
    return
  let place = locationName(language, location)
  var date = ""
  var time1 = ""
  if atSeconds > 0:
    date = dateText(atSeconds)
    time1 = timeText(atSeconds)
  var n = 0
  while n < ids.len:
    let id = ids[(start + n) mod ids.len]
    inc n
    let raw1 = localeText(language, id)
    if raw1.len == 0:
      continue
    var complete = false
    let filled = substitute(raw1, place, date, time1, complete)
    if not complete or filled.len == 0:
      continue
    return Spoken(text: filled, id: id, ok: true)

# ---------------------------------------------------------------------------
# The language the player reads in
# ---------------------------------------------------------------------------
#
# Kept per profile in this mod's own store rather than in the profile document,
# for the same reason the mailbox is: it is this server's bookkeeping and not
# something the client hands back. It is written from `/client/locale/<lang>`,
# which is the only place the client says what language it is in, and it is read
# when a message is composed -- including by the sweep that delivers insurance
# with nobody logged in, which has no session to ask.

const LanguageKeyPrefix* = "lang."

proc languageKey*(profileId: string): string = LanguageKeyPrefix & profileId

proc languageOf*(profileId: string): string =
  ## English until the client says otherwise, which is also what the launcher
  ## is told in `/client/game/config`.
  if profileId.len == 0:
    return "en"
  let raw1 = readKey(languageKey(profileId))
  if raw1.len == 0:
    return "en"
  let v = whole(raw1).field("lang").asText("")
  if v.len == 0:
    return "en"
  result = safeLanguage(v)

proc rememberLanguage*(profileId, language: string): bool =
  ## Records the language, and only when it changed -- the client asks for its
  ## locale table on every start and a store write per request buys nothing.
  ## A failure is not worth refusing a locale over: the caller discards this
  ## and the player gets English trader mail, which is what they got before.
  if profileId.len == 0:
    return false
  let want = safeLanguage(language)
  if languageOf(profileId) == want:
    return true
  var d = newDoc()
  setText(d, "lang", want)
  result = save(languageKey(profileId), text(d)) == Ok

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------

proc selfCheckDialogue*(into: var seq[string]): bool =
  ## Pure, over literals: the calendar, the placeholder filler and the pick.
  ## None of it touches the database, which is the point -- `emutest` runs
  ## against a fixture with no `dialogue` in it at all, so this is the only
  ## thing standing between a broken date and a mailbox full of `31.12.1969`.
  let before = into.len

  # The epoch, and the two boundaries that catch an off-by-one in the leap
  # rules: 2000 is a leap year (divisible by 400) and 1900 is not (divisible
  # by 100). -2208988800 is 1900-01-01.
  if dateText(0) != "01.01.1970":
    into.add "dialogue: the epoch formatted as " & dateText(0)
  if timeText(0) != "00:00":
    into.add "dialogue: midnight formatted as " & timeText(0)
  if dateText(951782400) != "29.02.2000":
    into.add "dialogue: 2000-02-29 formatted as " & dateText(951782400)
  if dateText(-2208988800) != "01.01.1900":
    into.add "dialogue: 1900-01-01 formatted as " & dateText(-2208988800)
  if dateText(1755529500) != "18.08.2025":
    into.add "dialogue: 2025-08-18 formatted as " & dateText(1755529500)
  if timeText(1755529500) != "15:05":
    into.add "dialogue: 15:05 formatted as " & timeText(1755529500)
  if timeText(86399) != "23:59":
    into.add "dialogue: the last minute of a day formatted as " &
             timeText(86399)
  # A timestamp before the epoch must not produce a negative time of day.
  if timeText(-1) != "23:59":
    into.add "dialogue: the second before the epoch formatted as " &
             timeText(-1)

  # The filler. Every placeholder the data uses, filled.
  var complete = false
  let all1 = substitute(
    "insured on {date} at {time} and lost somewhere on {location}",
    "Customs", "18.08.2025", "14:25", complete)
  if not complete:
    into.add "dialogue: a line with every value to hand was reported incomplete"
  if all1 != "insured on 18.08.2025 at 14:25 and lost somewhere on Customs":
    into.add "dialogue: substitution produced " & all1

  # A missing value is a refusal, not an empty gap, and the placeholder is
  # kept so the failure names itself.
  let missing = substitute("lost on {location}", "", "d", "t", complete)
  if complete:
    into.add "dialogue: a line missing {location} was reported complete"
  if missing != "lost on {location}":
    into.add "dialogue: an unfilled placeholder produced " & missing

  # A placeholder this server does not know is the same refusal. `{soldItems}`
  # is a real one, out of Fence's `soldItems` dialogue.
  discard substitute("here is your cut for {soldItems}", "L", "D", "T",
                     complete)
  if complete:
    into.add "dialogue: an unknown placeholder was reported complete"

  # And a line with no placeholders at all is complete, which is most of them.
  let plain = substitute("Sit tight, warrior.", "", "", "", complete)
  if not complete:
    into.add "dialogue: a line with no placeholders was reported incomplete"
  if plain != "Sit tight, warrior.":
    into.add "dialogue: a plain line came back as " & plain

  # The pick. Reproducible is the property that matters: the same message is
  # composed again whenever a delivery is retried after a failed save.
  if pickLine("seed", 0) != -1:
    into.add "dialogue: picking from an empty list did not refuse"
  if pickLine("seed", 1) != 0:
    into.add "dialogue: picking from a list of one did not pick it"
  let first = pickLine("profile.trader.insuranceFound.1700000000", 5)
  let again = pickLine("profile.trader.insuranceFound.1700000000", 5)
  if first != again:
    into.add "dialogue: the same seed picked " & $first & " then " & $again
  if first < 0 or first >= 5:
    into.add "dialogue: a pick from five lines was " & $first

  # And it does vary. A generator that returned the same index for everything
  # would pass every check above and give every trader one line forever.
  var seen: seq[int] = @[]
  var i = 0
  while i < 40:
    let at = pickLine("seed." & $i, 5)
    var known = false
    for s in seen:
      if s == at:
        known = true
    if not known:
      seen.add at
    inc i
  if seen.len < 3:
    into.add "dialogue: 40 seeds picked only " & $seen.len &
             " distinct line(s) out of five"

  # The path guard. A language is spliced into a dotted database path.
  if safeLanguage("ru") != "ru":
    into.add "dialogue: an ordinary language was rewritten"
  if safeLanguage("") != "en":
    into.add "dialogue: an empty language did not fall back to English"
  if safeLanguage("en.templates") != "en":
    into.add "dialogue: a language with a path separator in it was accepted"

  result = into.len == before
