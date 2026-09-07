## bm/prompt — the two halves of an LLM prompt, split so provider prompt
## caching can actually fire.
##
## `stablePrefix` is byte-stable for the same (world, faction, person): no
## timestamps, no counters, no turn numbers, nothing that changes between two
## consecutive turns with the same person. That is the whole reason it is a
## separate proc — a single stray `nowMs()` in here silently costs a full
## uncached prefix on every call, and `usage.cache_read_input_tokens` on
## `/status.llm` is the check that CAN fail when someone reintroduces one.
##
## `volatileSuffix` carries everything that does change: the moment, the memory,
## the retrieved facts and what was actually said.
##
## Neither proc imports `world`. Both take plain strings (`PersonCard`), so the
## brain can be exercised with a hand-written card and no world at all — which
## is exactly what the selfcheck does.

import std/strutils
import util

type
  PersonCard* = object
    id*, name*, faction*, factionCreed*, role*, voice*, traits*, wants*,
      forbids*: string
    attitude*, factionRep*: int
    mood*: float
    inventoryNote*: string
    placeName*, map*: string
    objective*: string
      ## What this person's GROUP is currently doing, as one clause
      ## ("moving the crates to the Quarry before dark"), from
      ## `bm/offscreen.objectiveSentence`. It is "" when they have no
      ## objective, and "" must stay distinguishable from "an empty one":
      ## the ontology row for `ask_activity` is only served when it is set.
    known*: string
      ## `world.renderKnown` -- the entities this person can talk about, with
      ## their ids. It is NOT in `stablePrefix`: knowledge grows every time a
      ## rumour reaches them, a cache is planted or a disclosure is made, so a
      ## prefix containing it would change between two consecutive turns and
      ## every provider prompt-cache read would miss. It goes at the TOP of the
      ## volatile suffix instead, where it is still the first thing the model
      ## reads.

  Situation* = object
    state*: string
    playerArmed*, playerAiming*: bool
    distanceM*: float
    playerHp*, npcHp*: float
    groupSize*: int
    timeOfDay*: string
    recentEvents*: string
    yell*: bool
      ## The player is too far for a normal voice but still inside shouting
      ## range (`bm/hearing`). It is in the VOLATILE half and NOT in
      ## `situationSignature`: two otherwise identical moments that differ only
      ## in whether the person has to shout need two different lines, and a
      ## cache that served the quiet one for both would be the bug.

proc distanceBand*(d: float): string =
  ## Three bands, deliberately coarse: the cache must match "the same KIND of
  ## moment", not the same float. 11.9 m and 12.1 m are the same moment.
  if d < 6.0: return "near"
  if d < 25.0: return "mid"
  result = "far"

proc situationSignature*(s: Situation): string =
  ## `state|armed|band|day`. Coarse on purpose (see above). Anything added here
  ## makes the line cache miss more often, so add only what would change the
  ## reply.
  var armed = "unarmed"
  if s.playerAiming: armed = "aiming"
  elif s.playerArmed: armed = "armed"
  var st = s.state
  if st.len == 0: st = "none"
  var tod = s.timeOfDay
  if tod.len == 0: tod = "day"
  result = st & "|" & armed & "|" & distanceBand(s.distanceM) & "|" & tod

proc tagGrammar*(): string =
  ## The LLM's ONLY actuator. Kept in one place so the parser in `brain` and the
  ## text handed to the model cannot drift apart: `knownTags()` below is the
  ## same list, and `bm/brain` drops anything not in it.
  result =
    "You may end your reply with tags, each on its own line. They are not " &
    "spoken; they are how you act on the world. Use only these:\n" &
    "[MOOD: -1..1, and move it by at most 0.4 in one reply]\n" &
    "[ATTITUDE: a small change, -15..+15 -- one conversation does not decide " &
    "how you feel about someone forever]\n[OFFER: <terms>]\n[ACCEPT]\n[REFUSE]\n" &
    "[DEMAND: <item or act> | <or else>]\n[GIVE: <item>]\n[TAKE: <item>]\n" &
    "[CAPTURE]\n[RELEASE]\n[FOLLOW_ME]\n[FOLLOW_YOU]\n[STAY]\n[LEAVE]\n" &
    "[ATTACK]\n[STAND_DOWN]\n" &
    "[QUEST: <title> | <brief> | <reward>]\n[QUEST_DONE: <id>]\n" &
    "[REMEMBER: <one line>]\n[RUMOUR: <one line>]\n[CALL: <personId>]\n" &
    "[OBJ: <objective>]\n[ADD: <objective>]\n[CLEAR]\n" &
    "Never mention the tags. Never write a bracket anywhere else.\n"

proc knownTags*(): seq[string] =
  result = @["MOOD", "ATTITUDE", "OFFER", "ACCEPT", "REFUSE", "DEMAND", "GIVE",
             "TAKE", "CAPTURE", "RELEASE", "FOLLOW_ME", "FOLLOW_YOU", "STAY",
             "LEAVE", "ATTACK", "STAND_DOWN", "QUEST", "QUEST_DONE", "REMEMBER",
             "RUMOUR", "CALL", "OBJ", "ADD", "CLEAR",
             "PLANT", "REVEAL", "EXPECT", "CLAIM_OK", "CLAIM_FAIL"]

proc modelForbiddenTag*(name: string): bool =
  ## `CLAIM_OK` / `CLAIM_FAIL` are the ENCOUNTER MACHINE's own record of a
  ## believability roll. They are in `knownTags` because `applyTags` must map
  ## them, and they are NOT in `tagGrammar` because the model is never told
  ## about them -- if it invents one anyway the brain drops it here, with a
  ## note. A model that could write its own verdict would make the roll
  ## unfalsifiable.
  result = name == "CLAIM_OK" or name == "CLAIM_FAIL"

proc attitudeWord*(a: int): string =
  if a <= -60: return "you hate them"
  if a <= -20: return "you distrust them"
  if a < 20: return "you have no strong feeling about them"
  if a < 60: return "you like them"
  result = "you would take a bullet for them"

proc moodWord*(m: float): string =
  if m <= -0.6: return "black"
  if m <= -0.2: return "sour"
  if m < 0.2: return "flat"
  if m < 0.6: return "decent"
  result = "good"

proc stablePrefix*(worldPrompt, rules: string; c: PersonCard): string =
  ## BYTE-STABLE for a given (worldPrompt, rules, card). Do not add anything
  ## time-varying here; put it in `volatileSuffix`.
  var s = "THE WORLD\n"
  s.add oneLine(worldPrompt)
  s.add "\n"
  if rules.len > 0:
    s.add "RULES OF THIS WORLD\n"
    s.add rules
    if not rules.endsWith("\n"): s.add "\n"
  s.add "\nWHO YOU ARE\n"
  s.add "You are " & c.name & ", a " & c.role & " of " & c.faction & ".\n"
  if c.factionCreed.len > 0:
    s.add c.faction & " believes: " & oneLine(c.factionCreed) & "\n"
  if c.traits.len > 0: s.add "You are " & c.traits & ".\n"
  if c.wants.len > 0: s.add "You want: " & c.wants & ".\n"
  if c.forbids.len > 0: s.add "You will not: " & c.forbids & ".\n"
  if c.placeName.len > 0:
    s.add "You hold " & c.placeName & " on " & c.map & ".\n"
  if c.inventoryNote.len > 0: s.add "You are carrying " & c.inventoryNote & ".\n"
  s.add "\nHOW YOU SPEAK\n"
  s.add "One to three short spoken sentences. Out loud, to their face. " &
        "Never narrate an action, never use markdown, never say you are an AI, " &
        "never break character. People here are tired, hungry and armed; talk " &
        "like it.\n"
  s.add "\n" & tagGrammar()
  result = s

proc volatileSuffix*(c: PersonCard; s: Situation; memory, facts,
                     utterance: string): string =
  var v = "THE MOMENT\n"
  v.add "Encounter: " & (if s.state.len > 0: s.state else: "none") & ". "
  v.add "They are " &
        (if s.playerAiming: "aiming a weapon at you"
         elif s.playerArmed: "armed but not aiming"
         else: "not holding a weapon") & ", "
  v.add distanceBand(s.distanceM) & " (" & $int(s.distanceM) & " m). "
  v.add "Their condition " & $int(s.playerHp * 100.0) & " percent, yours " &
        $int(s.npcHp * 100.0) & " percent. "
  if s.groupSize > 1: v.add "You have " & $(s.groupSize - 1) & " with you. "
  v.add "It is " & (if s.timeOfDay.len > 0: s.timeOfDay else: "day") & ".\n"
  if s.yell:
    v.add "Yell: true. They are " & $int(s.distanceM) &
          " m away -- too far to talk to. SHOUT one short line, six words at " &
          "most, the way a person shouts across a yard. No sentences, no " &
          "explanation.\n"
  v.add "Toward this person: " & attitudeWord(c.attitude) &
        " (attitude " & $c.attitude & ", your faction's standing with them " &
        $c.factionRep & "). Your mood is " & moodWord(c.mood) & ".\n"
  if s.recentEvents.len > 0:
    v.add "\nWHAT JUST HAPPENED\n" & s.recentEvents
    if not s.recentEvents.endsWith("\n"): v.add "\n"
  if facts.len > 0:
    v.add "\nWHAT YOU KNOW\n" & facts
    if not facts.endsWith("\n"): v.add "\n"
  if memory.len > 0:
    v.add "\nWHAT HAS BEEN SAID BETWEEN YOU\n" & memory
    if not memory.endsWith("\n"): v.add "\n"
  v.add "\nTHEY SAY\n"
  v.add (if utterance.len > 0: oneLine(utterance) else: "(nothing; they just stand there)")
  v.add "\n\nAnswer as " & c.name & ".\n"
  result = v
