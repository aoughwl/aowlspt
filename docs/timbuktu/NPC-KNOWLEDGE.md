# The NPC knowledge system

*Escape from Timbuktu, pillar 3. Design only — nothing here is implemented, and
several things here are argued to be unimplementable on the surface this repo
has today.*

The brief for this pillar was: "there is a very complex npc 'knowledge' system
which is what their GPT uses to both have a single prompt and available tools."
This document takes that seriously and takes it apart. The model call is the
least interesting part. What decides whether an NPC is a character or a chatbot
is the substrate underneath it: what this one NPC knows, when it learned it,
from whom, whether it is true, and what it is permitted to *do* about it.

The governing sentence of this repository applies here more than anywhere:
**nothing in this tree has ever run against BSG's client.** Every claim below
about what the player can type, what a bot can be made to do, and what route the
client posts to is marked as verified-in-repo, verified-in-dump, or unverified.

---

## 1. What exists today

### 1.1 The server is a mod, and it is a real server

`mods/tarkov` is a complete Tarkov server written against the public mod API
(`aowlspt`, `aowlspt/server`, `aowlspt/json`) and nothing else — 40-odd modules
under `mods/tarkov/emu/`, documented in `docs/EMULATOR.md`. The parts that bear
on this pillar:

| module | what it already gives this pillar |
|---|---|
| `emu/mail.nim` | a durable, bounded per-profile inbox: `deliver(profileId, sender, text, kind, ...)` at line 303 posts a message from any sender id; `dialogList` / `dialogView` render it; attachments are real items in a real container. **This is the conversation transport.** |
| `emu/notify.nim` | `notifyOrQueue(session, payload)` — pushes over the client's notifier websocket via the revision-5 `notifyPush`, and falls back to an in-memory queue drained by `/client/notifier/getwebsocket`. **This is what makes an asynchronous reply possible.** |
| `emu/dialogue.nim` | resolves `traders.<id>.dialogue.<situation>` through `locales.global.<lang>`, fills `{location}` / `{date}` / `{time}`, and **refuses** (`Spoken.ok == false`) rather than emit a half-filled line. `say()` picks reproducibly from a seed. |
| `emu/traders.nim` | the twelve traders: `traderIds()`, `traderBase`, `traderAssort`, loyalty (`loyaltyLevelFor`, `refreshLoyalty`), standing (`addStanding`, `scavKillKarma`). |
| `emu/trading.nim` | barter already works: `takePayment` resolves a `barter_scheme` to (stack, amount) pairs, verifies **all** of them, and only then takes anything. `buyFromTrader`, `sellToTrader`, `giveItem`. |
| `emu/quests.nim` | quest state on the profile, conditions evaluated by `emu/questcond`, rewards posted through the mailbox. |
| `emu/store.nim` | the `Stored.missing` discipline: "nothing here" and "here and unreadable" are different answers, and a writer refuses on the second. |
| `emu/ids.nim`, `emu/rand.nim` | no global entropy anywhere in the emulator. Ids are run-numbered and persisted; randomness is seeded from stored text. |
| `emu/sessions.nim` | session id → profile, persisted, because the client does not re-select after a server restart. |

### 1.2 The mod-facing API

`aowl/src/aowlspt/server.nim` is the whole backend surface a mod gets:

- `serve(url, handler)` / `servePrefix` — routes.
- `dbRead(path)` / `dbWrite(path, patch)` — the JSON database by dotted path,
  merging on write (`backend/jsondb.nim:1364 dbPatchPath`).
- `dbKeys(path, into)` and `dbKeysOrRead` (`server.nim:337`, `:380`) — key
  enumeration over the `?keys ` sigil, backed by `jsondb.dbKeysRequest` /
  `dbKeysPath`.
- `save` / `load` / `saved` / `savedKeys` — the per-mod store.
- `broadcast(name, payload)` / `onEvent(name, handler)` — mod-to-mod events.
- `afterMs` / `everyMs` — timers, off the request threads.
- `setting(key)` — this mod's `config.json`.

That list is exhaustive and the exhaustiveness is the point. **There is no
outbound HTTP client, no socket, no process spawn and no file API in the ABI**
(`abi/aowlspt_abi.h`, `AowlHostApi`). A mod that wants any of those does it
itself, in-process.

### 1.3 The precedent for calling anything off-box: `mods/manager/mgr/httpfetch.nim`

This file is the single most important thing I found for this pillar. It is a
non-blocking HTTP GET, written for the mod manager's registry fetch, and its
docstring states the exact discipline an LLM call needs:

- `start(url, ...)` → a job or a refusal, immediately; `poll(job)`; `take(job)`.
- The worker is **C** and runs on a thread the nimony runtime has never seen: it
  allocates nothing, calls no nimony code, and writes only into a `malloc`
  buffer the starting thread gave it. Everything nimony-shaped happens back on
  the mod's own thread after the flag flips.
- WinHTTP is `LoadLibraryA("winhttp.dll")`, resolved by name, so nothing is
  added to the shared mod link line, and a machine without it fails *softly*.
- A job outliving the mod is handled: `release` marks it abandoned and hands the
  buffer to the worker to free.
- One deadline bounds the whole fetch, not each operation.

An LLM request is this file with `POST`, a body, and a longer deadline. That is
a real, small, already-argued piece of engineering rather than a hope.

### 1.4 The client side, and why it constrains this pillar hard

`docs/IL2CPP.md` and `mods/sain/README.md` are the honest account. Post-1.0 is
IL2CPP with encrypted metadata: no BepInEx, no Harmony, no C# plugins. A client
mod gets native detours plus the IL2CPP API — `game.nim`'s `gameType` /
`invoke` / `field` boxed path, and `aowlspt/fast` for ~10 ns bound calls.

`mods/sain` is the largest thing anyone has built on that, and it drives bots.
Its "driving calls" section names *five* channels — `Mover.GoToPoint`,
`Mover.Sprint`, `Steering.LookToPoint`, `ShootData.Shoot`, `Mover.Stop` — plus
four self-actions (`Reload.TryReload`, `FirstAid.TryApplyToCurrentPart`,
`Stimulators.TryApply`, `SurgicalKit.TryApplyToCurrentPart`). Every one is
signature-gated by `core/sig.nim` and refuses rather than calls wrong. And
`mods/sain/README.md` §4 says plainly: **nothing in this repo has ever executed
one of them against BSG's client.**

So the reachable vocabulary of NPC *action* in the world is: go there, sprint,
look there, shoot, stop, reload, heal. There is no "hand this item over", no
"open that chest", no "speak this line", no nameplate, no TTS. Bot voices are a
template id in `Customization.Voice` chosen at generation time
(`emu/bots.nim`), and a generated bot is a throwaway profile the server never
sees again except as a row in the raid-end victim list.

### 1.5 Where the brief is wrong, or at least optimistic

Five corrections, all load-bearing:

1. **"Every NPC is driven by a language model" is not currently expressible for
   in-raid NPCs.** The only NPCs with a durable server-side identity are the
   twelve traders in `traders.*`. Everything else is a bot profile assembled per
   raid by `emu/bots.nim` from `bots.types.<role>` and then discarded. Giving a
   raid bot a persistent mind means this project first inventing persistent bot
   identity — which is a *persistence* problem, not a knowledge one, and
   `docs/timbuktu/PERSISTENCE.md` should be told so.

2. **There is no confirmed free-text channel from the player to an NPC.**
   `reference/spt-4.1-surface.txt` carries the *types* — `SendMessageRequest`
   with `Type` / `DialogId` / `ReplyTo` / `Text` at line 7654,
   `IDialogueChatBot`, `AbstractDialogChatBot`, `CommandoDialogChatBot`,
   `DialogueController.SendMessage(sessionId, request)` — so SPT 4.1's server
   plainly accepted typed messages and dispatched them to chat bots. But the
   dump carries **no route URLs at all** (`grep -c '/client/'
   reference/spt-4.1-surface.json` is 0), and `mods/tarkov` serves no send
   route: `tarkov.nim:1605-1612` registers `dialog/list`, `info`, `view`,
   `getAllAttachments`, `read`, `pin`, `unpin`, `remove` — and no `send`.
   Whether the post-1.0 *client* still offers a text box that posts one is
   unverified here. **This is the highest-risk unknown in the pillar** (§4.1).

3. **"A single prompt" cannot mean one prompt shared across NPCs.** Two NPCs
   holding contradictory beliefs is the stated requirement; a shared prompt is
   the one thing that makes it impossible. What is achievable, and what I think
   the owner means, is a single *system template* — one persona-and-rules
   scaffold, one tool schema — filled per NPC from that NPC's own store. That is
   also what makes prompt-prefix caching work (§3.2), so it is worth wanting.

4. **Barter already exists.** `emu/trading.takePayment` resolves real
   `barter_scheme` entries. The pillar does not have to invent bartering; it has
   to decide *what an NPC is willing to barter*, which is a knowledge question.

5. **`docs/API-GAPS.md` gap 2 is stale.** It says there is no `dbKeys(path)`.
   There is: `server.nim:337`. Gap 1 (`tarkov.raid.ended` carrying only the
   profile id) is *not* stale and is a blocker for this pillar — see §5.1.

---

## 2. The knowledge model

### 2.1 Two layers, and the reason they are separate

**Layer 0 — the event log.** Append-only, server-authored, small, structured.
Nothing but the emulator's own code writes it: a raid ended here with these
victims, this trade happened, this quest advanced, this craft finished, this
chest was opened. It is the record of what is *true*. No NPC reads it directly
and no model ever sees it.

**Layer 1 — belief stores.** One per NPC. A belief is a claim *about* the world,
held by one mind, possibly wrong, possibly contradicted by that same mind's
other beliefs. This is what the model sees.

The separation is not tidiness. It is what makes "two NPCs hold contradictory
beliefs" representable without the store fighting itself, and it is what makes
save/load tractable (§4.3): the event log is the authority, and every belief
store can in principle be rebuilt from it plus the propagation rules, because
propagation is deterministic (§2.6).

It is also the same shape `mods/tarkov` already uses everywhere: the profile is
the durable record and a notification is a derived, disposable thing
(`emu/notify.nim`: "the queue is in memory and deliberately not persisted").

### 2.2 What a belief is

Keeping most of the suggested spine and rejecting it in four places. The
suggestion was subject / value / provenance / confidence / timestamp / decay. I
want:

```
Belief = {
  s    : EntityRef      subject     — must resolve
  p    : PredicateId    predicate   — from a closed vocabulary
  o    : Operand        object      — EntityRef | enum | quantity | place | time
  n    : bool           polarity    — true = denies the proposition
  c    : uint8          confidence  0..255
  src  : Provenance     witnessed | told(npcId) | inferred(ruleId) | rumour | self
  te   : int            when the thing it is about happened  (unix seconds)
  tl   : int            when this NPC learned it             (unix seconds)
  hl   : DecayClass     half-life class (see 2.5)
  root : BeliefId       chain of custody: the belief this descends from
  v    : Veracity       server-only: agrees | contradicts | unknowable
}
```

The four departures, each for a reason:

- **Polarity is separate from confidence.** "I am sure Prapor does not have
  ammo" and "I have no idea whether Prapor has ammo" are different states, and
  collapsing them into a low confidence loses the first. An NPC that can
  confidently deny is an NPC that can be *wrong* in an interesting way.
- **Two timestamps.** `te` is when the event happened; `tl` is when this mind
  learned it. Stale news and old news are different: a rumour learned today
  about a raid three weeks ago is fresh to its holder and useless to the player.
  Decay runs on `te`; recency-of-acquisition runs on `tl`.
- **`root` — chain of custody.** Every belief points at the belief it was copied
  from, transitively back to a witnessed original or to a fabrication. This is
  what makes a lie *traceable*: when the player catches a false claim, the
  server can walk `root` and weaken it in every mind downstream, which is how a
  reputation collapse propagates. Without it, a lie is indistinguishable from an
  honest error.
- **`v` — a hidden veracity flag** the server stamps by checking the belief
  against the event log at write time. **The model never sees it.** It exists
  for three things: consequences ("you lied to me" is only checkable if the
  server knows), the debug overlay, and the self-test, which asserts that a lie
  injected at NPC A shows up as `contradicts` in NPC C after two gossip hops.

`EntityRef` is a tagged id: `i:<templateId>` for an item template,
`t:<traderId>`, `l:<locationId>`, `q:<questId>`, `n:<npcId>`, `c:<chestId>`,
`p:<profileId>`. **A ref that does not resolve cannot be constructed.** That
single rule is most of the grounding story (§3.5).

`PredicateId` is a closed enum, not a string. First cut, about twenty-four:

```
has / wants / lacks            (subject, item, quantity)
sells / buys / refuses         (trader, item, price band)
located / moved / cached       (entity, place)
killed / died / survived       (actor, victim | actor, place)
owes / paid / cheated          (actor, actor, amount)
allied / hostile / afraid      (actor, actor)
opened / looted / hid          (actor, container)
saw / heard / told             (actor, actor, belief)
route_open / route_shut        (place, place)
quest_offered / quest_done     (trader, quest, actor)
```

A predicate the vocabulary does not have is not a belief. This is the same
refusal `emu/dialogue.substitute` makes about an unknown `{placeholder}`: the
data does not say, so nothing is said.

### 2.3 Contradiction is normal and is never normalised away

A belief store is **not** a map from `(s, p)` to a value. It is a set. Two
beliefs with the same subject and predicate and different objects coexist
forever, or until one decays out.

Reading requires a *stance*, computed at read time and never written back:

```
weight(b) = c(b) * decay(b, now) * trust(holder, src(b)) * corroboration(b)
```

- `trust` is a per-NPC matrix over other NPCs and over the player, 0..1,
  persisted, moved by outcomes (§2.6). `witnessed` is 1.0 by definition;
  anonymous `rumour` sits at a floor, say 0.2.
- `corroboration` counts *independent* supporting beliefs — independent meaning
  a different `root`. Three copies of one rumour arriving by three routes is one
  piece of evidence, and getting that wrong is how a rumour mill becomes a
  certainty machine. It is the same defect as "a bounded list filled from one
  source is not a bound" in `docs/EMULATOR.md`, one level up.

The stance is `(best, runnerUp, margin)`. A narrow margin is *doubt*, and doubt
is renderable: the prompt gets "you believe X, but you have also heard Y" and
the NPC hedges. An NPC that hedges because its store actually contains a live
contradiction is the whole payoff of this design.

### 2.4 How facts are indexed for retrieval

Explicitly **not** embeddings, and this is the decision I would most expect an
argument about. Reasons: a local embedding model is a second model to ship,
load and keep resident beside a generation model on a GPU that Tarkov already
wants; embeddings retrieve by vibe, and the retrieval this system needs is by
*entity*, which is exact; and an embedding index is a blob that cannot be
diffed, tested, or explained when it retrieves the wrong thing. The repo's house
style — `emu/dialogue.selfCheckDialogue`, `mods/sain/core/selftest.nim`'s 124
pure checks — depends on being able to test the thing with no runtime.

Four indices per NPC, all rebuilt on load, all plain arrays:

1. **By subject** — hash of `EntityRef` → belief ids. The primary path.
2. **By predicate** — for "what do you want?" style questions.
3. **By recency of acquisition** — a ring over `tl`, for "what's new".
4. **By salience** — a small max-heap over `weight * topicWeight(npc)`, where
   `topicWeight` is the NPC's persona-declared interest (Prapor cares about
   `sells`/`has` on weapons; Therapist about `died`/`hostile`).

Retrieval for one turn:

```
seed   = entity refs named in the player's message, resolved by the
         name->id lexicon (§3.5), plus refs from the last three turns
expand = one hop along `saw` / `told` / `located` from each seed
fill   = top-k by salience, then top-k by recency, until the budget is spent
```

One hop, not two. Two hops on a dense store pulls in everything, and the token
budget then chooses for you, arbitrarily. Better to under-retrieve
deterministically than to over-retrieve and let a truncation decide what the NPC
remembers.

### 2.5 Decay

`hl` is a class, not a number, so it is legible and tunable from `config.json`:

| class | half-life | example |
|---|---|---|
| `volatile` | 2 h | who is on Customs right now |
| `market` | 24 h | what a trader had in stock |
| `episodic` | 7 d | a raid, a kill, a trade |
| `structural` | 90 d | a route being open, where a chest is |
| `identity` | never | who somebody is, who wronged whom |

`decay(b, now) = 0.5 ^ ((now - te) / halfLife(hl))`. Below a floor — say 0.05
weight — a belief is **not deleted**. It moves to a cold ring, kept for `root`
chain integrity and for "I knew that once", and is evicted only when the per-NPC
cap is hit. Deleting outright breaks the custody chain for everything downstream
of it.

Decay is computed, never stored. Same reasoning as `emu/hideout`'s craft
progress being `now - StartTimestamp` rather than a counter: a server switched
off for a week comes back agreeing with one that ran the whole time.

### 2.6 How an NPC learns — and how lies propagate

Three ingestion paths, and **none of them is the language model.** This is the
central safety property of the design: *the model cannot author a fact.*

**Witnessing.** The emulator's own code emits into the event log; a rule table
maps each event kind to the beliefs each NPC in scope forms, with
`src = witnessed`, `c = 240`, and `v` stamped `agrees` by construction. Scope is
a per-event predicate: a trade is witnessed by its two parties; a raid death by
whoever was on that map; a market movement by the traders who deal in that
category. Blocked today on API-GAPS gap 1 (§5.1).

**Telling.** When NPC A tells B something, the pipeline does not take the
model's prose. It takes A's structured `tell` tool call, which names *one of A's
own belief ids* — an id that must have been in A's prompt. The server then
constructs B's copy:

```
b' = { s, p, o, n   from A's belief, possibly mutated by A's deception policy
       c            = A.c * trust(B, A) * channelLoss
       src          = told(A)
       te           = A.te            (the event's time, not now)
       tl           = now
       root         = A.root          (custody survives the hop)
       v            = restamped by the server against the event log }
```

**The deception policy is the server's, not the model's.** A per-NPC disposition
(`honest` / `self-serving` / `hostile` / `paranoid`) plus a deterministic RNG
seeded exactly the way `emu/rand.seededRng` is — from stored text, never from a
clock — decides whether this particular telling is faithful. The mutations
available are small and enumerable: flip `n`, shift `o` to a neighbouring entity
or an adjacent quantity band, inflate `c`, or substitute the object with
something that benefits A. That is the whole set.

Why the server and not the model: a model asked to "lie sometimes" lies
unpredictably, unreproducibly, and about things that do not exist. A server that
lies from a table produces misinformation that is *typed*, *traceable* through
`root`, *reproducible* across a save/load, and *testable* — the self-test can
assert that a fabrication injected at A reaches C as `contradicts` after two
hops with confidence in a predicted band, with no model running at all.

**Rumour.** A background pass on `everyMs` — say every five minutes of server
time — walks a social graph (who talks to whom, per-pair rate and topic filter)
and moves beliefs along it with the same construction. This runs with **no model
involvement whatsoever**. It is pure arithmetic. The world's information ecology
keeps evolving while the player is in a raid, offline, or has the LLM disabled
entirely.

That last point deserves emphasis: **the knowledge system is the game feature;
the language model is a rendering layer over it.** If the model never runs, the
world still has gossip, misinformation, decayed memories and NPCs who disagree —
it just expresses them through templated lines instead of prose. Designing it
the other way round makes the entire pillar contingent on a GPU.

### 2.7 Inference

A small closed rule set, run at ingestion, `src = inferred(ruleId)`:

- `has(X, item)` and `sells(X, item)` ⇒ `wants(X, currency)`.
- `killed(A, B)` told to C where `allied(C, B)` ⇒ `hostile(C, A)`, low `c`.
- `route_shut(P, Q)` ⇒ weaken cached `located(x, Q)` beliefs.

Inferences are beliefs like any other, decay like any other, and carry `root`
back to their premises, so retracting a premise weakens the conclusion. One
pass, depth one. Depth two is where a rule set starts producing garbage nobody
can trace.

---

## 3. The prompt and tool contract

### 3.1 Shape of one turn

```
player types  -> route accepts, returns immediately ("<npc> is typing")
              -> turn queued
              -> retrieval builds a context pack (pure, fast, ~1 ms)
              -> LLM job started on the C worker thread
              -> ... 0.5-8 s ...
              -> tool calls validated and executed against emulator procs
              -> prose posted via emu/mail.deliver
              -> emu/notify.notifyOrQueue wakes the client
```

The conversation rides the **mailbox**, which is already asynchronous, already
durable, already bounded, and already has a push channel. That is not a
workaround for latency — it is the reason this pillar is feasible at all, and it
should be treated as a hard architectural commitment rather than a v1 shortcut.
See §4.2.

### 3.2 The single system template

One template, filled per NPC. Ordered so the stable parts come first, because
that ordering is what a local server's KV prefix cache keys on:

```
[A] rules and tool schema      ~900 tokens   identical for every NPC, forever
[B] persona card               ~250 tokens   per NPC, changes ~never
[C] world frame                ~120 tokens   date, season, where the NPC is,
                                             the player's standing and loyalty
[D] belief block               ~900 tokens   the retrieved pack
[E] conversation               ~600 tokens   last N turns verbatim plus a
                                             rolling summary of older ones
[F] the player's message       ~100 tokens
```

Roughly 2.9k tokens in, capped at 3.5k, generating at most 200. [A]+[B] are
byte-identical between turns for one NPC, so a llama.cpp-class server reuses the
KV cache for ~1.1k tokens of prefill on every turn after the first. That is not
a micro-optimisation: on a CPU-only or GPU-shared setup, prefill is most of the
latency.

### 3.3 How a belief renders

Compact, id-tagged, one line each, sorted by weight descending:

```
b3   you saw   Prapor sell 5.45 BP [i:5c0d5e4486f7747...] at 700r   3d ago  sure
b7   Skier told you the north road [l:bigmap>l:rezervbase] is shut   1d ago  unsure
b9   ...but you saw it open yourself                                6h ago  sure
b12  rumour: someone cached medical [i:...] at the blue chest [c:41]  ?      doubt
```

Four rules about this rendering:

- **Every line has a handle** (`b3`). The model must cite handles in its tool
  calls. A tool call citing a handle that was not in this prompt is refused
  before its arguments are even parsed. This is the cheapest and strongest
  anti-hallucination gate in the system.
- **Every entity carries its id in brackets.** The model must emit the id, not
  the name. Names are for the prose it speaks; ids are for the tools it calls.
- **Confidence renders as a word, not a number** — `sure` / `unsure` / `doubt` /
  `heard`. Models handle four buckets far better than they handle 0.73, and it
  keeps the prompt honest about the precision actually available.
- **Contradictions render adjacently and are labelled** (`b7` / `b9` above). If
  they are ten lines apart the model will silently pick one.

### 3.4 The tools

Every tool is a thin wrapper over an emulator proc that already exists and
already validates. The model gets *no* new authority.

| tool | backed by | gate |
|---|---|---|
| `speak(text)` | `emu/mail.deliver` | length cap; the only tool with no knowledge gate |
| `tell(npc, beliefId)` | §2.6 telling | the belief must have been in this prompt |
| `offer_trade(item, qty, price)` | `dbWrite("traders.<id>.assort...")`, then `emu/trading.buyFromTrader` | must hold `has(self, item)`; price inside the persona's band |
| `request_barter(wants, gives)` | `emu/trading.takePayment` | must hold `wants(self, X)` |
| `offer_quest(questId)` | `emu/quests` | the quest must be in this NPC's owned set |
| `set_disposition(delta)` | trust matrix + `emu/traders.addStanding` | clamped per turn |
| `reveal_location(entity)` | a belief write on the player's side | must hold `located(entity, place)` above a weight threshold |
| `recall(query)` | a second retrieval pass | at most once per turn |
| `refuse(reason)` | nothing | always available |

`recall` is the one tool that reaches back into the store mid-turn. It costs a
second round trip and is capped at one, because a model given unlimited
retrieval will use it instead of thinking.

Note what is absent: no `give_item`, no `move_to`, no `spawn`, no
`create_quest`, no unbounded `set_price`. An NPC cannot manufacture value. Every
item that changes hands goes through `emu/trading`, which prices from the
handbook and the `barter_scheme` and counts from the profile — exactly as
`docs/EMULATOR.md` describes for the player. The model is just another untrusted
request body, and this server's entire design philosophy is *the request does
not get to do the arithmetic*.

### 3.5 Grounding — the three gates

A tool call passes three gates in order, and the failure of any one is a **typed
refusal returned into the conversation**, not an exception:

**Gate 1, resolution.** Every argument that is an `EntityRef` must resolve:
`dbRead("templates.items." & id)`, `dbRead("traders." & id)`,
`dbRead("locations." & id)`, the chest registry from the persistence pillar, the
NPC roster. Non-resolving → `REFUSED: no such entity`. This is what stops an NPC
inventing an item. The model cannot emit a name and have it become real, because
names are not accepted as arguments at all — only ids, which it can only have
got from the prompt, which only ever contained ids that resolved when the belief
was written.

The name→id lexicon that lets the *player* say "ammo" runs the other way and
runs outside the model: built from `locales.global.<lang>` — the same table
`emu/dialogue.localeText` already reads — plus the handbook. It is a lookup, not
a generation.

**Gate 2, knowledge.** Does this NPC hold a belief licensing this call, and was
that belief in this prompt? `offer_trade(X)` needs `has(self, X)`.
`reveal_location(C)` needs `located(C, P)`. Missing → `REFUSED: you do not know
that`, fed back for exactly one retry. One, because a model that can retry
forever will eventually find a call that passes.

**Gate 3, authority.** A per-NPC capability set: which tools at all, which quest
ids it owns, its price band, its stock, its per-turn disposition delta. `speak`
and `refuse` are the only two everybody has.

Where the backend has it, the JSON is additionally forced by grammar-constrained
decoding (llama.cpp GBNF, or `response_format: json_schema`). That is a
*backend-specific* optimisation, not the mechanism: it degrades to
parse-and-refuse on a backend that lacks it, and the gates run identically
either way. A design that depends on constrained decoding is a design that
breaks when the user swaps runtimes.

### 3.6 The lie the model is allowed to tell

None, in the sense that matters. The model chooses *words*; it does not choose
facts. An NPC's deceptions are constructed by §2.6 before the prompt is built
and arrive in the belief block already mutated — so the NPC is sincerely
reporting a belief that happens to be false, which is also how most human lying
in a rumour economy actually works. Deliberate deception (an NPC that knows the
truth and says otherwise) is expressed by a `speak` whose content the persona
card instructs to contradict belief `bN` — and the *belief written into the
listener* still comes from the server's mutation table, not from the prose. The
prose and the propagated fact are generated by different mechanisms, on purpose.

---

## 4. The hard questions, answered

### 4.1 The channel — and the thing that could sink this pillar

Everything above assumes the player can send free text to an NPC. In this repo
that is **unverified**. `SendMessageRequest` (Text / DialogId / ReplyTo / Type)
and the `IDialogueChatBot` family are in `reference/spt-4.1-surface.txt`, so SPT
4.1's *server* took typed messages. The dump has no route URLs, and
`mods/tarkov` serves no send route.

Contingency, in preference order:

1. **The route exists.** Serve it, and this pillar is as designed.
2. **The route exists but the post-1.0 client has no UI that posts to it.** Then
   the input channel is the overlay (`host/Aowlspt.Overlay`) — a separate
   window, out of immersion, but it works and it is entirely within this repo's
   reach.
3. **Neither.** Then the player's side of every conversation is a *menu of
   generated choices*: the server generates three or four candidate player
   utterances from the belief state and posts them as a mail message whose
   reply-to ids encode the choice. Clunky, and it still needs a click that
   reaches the server. Worst case the player has no voice at all, and the pillar
   reduces to NPC↔NPC gossip that the player observes through what traders say
   and what they stock — which, note, is still a real feature and still worth
   building, because none of §2 depends on the player talking.

**Design so that (3) is a degradation, not a rewrite.** Concretely: the belief
system, the gossip tick, the deception table and the tool gates must all be
implementable and testable before the channel question is settled.

### 4.2 Latency and cost

**Nothing touches the game thread. Ever.** This is a backend-side mod
(`side() == sideServer`). Route handlers run on the backend's request threads;
the gossip and decay passes run on `everyMs`; the HTTP worker is a C thread the
nimony runtime has never seen (`httpfetch.nim`'s discipline, §1.3). A 16 ms
frame is never in the same call stack as a token.

**The 100 ms–8 s round trip is hidden by the transport, not raced against it.**
The mail route answers immediately. There is no frame to miss and no animation
to stall, because in v1 the NPC is a correspondent, not a body in the world
(§4.5). *What does the NPC do while waiting?* Nothing — it is a mailbox. That is
a deliberate scoping choice and it is what makes the latency question tractable
at all; a design that puts an LLM into a face-to-face conversation with a
rendered character needs sub-300 ms and cannot have it.

**Concurrency.** One in-flight generation per NPC, hard. A global cap of two
concurrent, because a local model is one GPU and the third request makes the
first two slower without finishing sooner. A bounded queue — sixteen turns —
with an **age drop**: a turn older than 30 s is dropped and answered from the
fallback ladder, the same discipline `mods/sain` uses for its 350 ms driving
orders. Drops are counted and reported in one state line, so "never running" and
"not yet" can be told apart — again SAIN's rule.

**Cached.** (a) The system prefix [A]+[B], byte-stable, so the server's KV cache
hits. (b) The rendered belief block per NPC, invalidated on any belief write for
that NPC — most turns do not change the store. (c) The name→id lexicon, built
once at load from the locale table.

**Precomputed.** Greetings, refusals, haggling responses, and "what's on my
mind" one-liners, generated during an idle pass when the store is quiet and no
player is logged in, then served instantly. An NPC's *opening line* being
instant does most of the work of making the whole system feel responsive.

**When the model is slow or unavailable — the fallback ladder.** In order:

1. A template line rendered from the stance, deterministically. The templates
   are per-predicate and per-disposition; there are maybe two hundred of them;
   they are the same idea as `emu/dialogue.say` and should reuse its
   pick-reproducibly-from-a-seed machinery.
2. The trader's own BSG line out of `traders.<id>.dialogue.<situation>` via
   `dialogue.say`, which already exists and already refuses rather than emit a
   half-filled sentence.
3. Silence, plus a working trade UI.

And the invariant that makes the ladder acceptable: **every tool the model can
call, the player can also reach through the ordinary client UI.** Nothing is
gated behind a successful generation. A player with no model configured plays a
complete game with quieter NPCs.

**Cost.** Zero, by construction — see §4.4.

### 4.3 Determinism, and what the persistence pillar has to store

**The rule: if it did not go through a tool call, it did not happen.** Prose is
cosmetic. That single rule makes the world deterministic while the language is
not, and it is what makes save/load honest.

Persisted — the persistence pillar's problem, and it should be told these key
shapes, flat and matching `host/common/modstore.nim`'s `validKey`
(`[A-Za-z0-9._-]` only):

| key | content | bound |
|---|---|---|
| `npc.log.<epoch>` | the event log, chunked by epoch | rotate at 4k events |
| `npc.bel.<npcId>` | that NPC's belief store | 512 hot + 256 cold, hard cap |
| `npc.trust` | the trust matrix (small, dense) | one document |
| `npc.rng` | the deception and gossip stream positions | one document |
| `npc.chat.<npcId>.<profileId>` | last twelve turns verbatim + rolling summary | 8 KB cap |

**Both the belief store and the conversation history are persisted, but they are
not equally important.** The belief store is the world; losing it loses the
campaign. The transcript is continuity flavour; losing it means an NPC forgets
the *wording* of yesterday but not the *facts*, because the facts are beliefs.
If the persistence pillar has to choose what to protect, it protects beliefs.

Three hazards to hand over explicitly, all of them already-learned lessons in
this tree:

1. **Unbounded growth.** `emu/mail.nim` grew 267 bytes per play cycle,
   monotonically, and a 200-cycle soak took average request latency from 797 µs
   to 105 ms. A belief store will do exactly that, faster. Hence the hard caps
   and epoch chunking above. The store is one file per key and a write rewrites
   the whole value (`modstore.storeWrite`), so an unbounded key is an unbounded
   write on every change.
2. **`Stored.missing` discipline.** `emu/store.nim`: "nothing here" and "here
   and unreadable" must be different answers, and a path about to write must
   refuse on the second. A belief store overwritten with an empty one because of
   a transient read error is a campaign silently reset.
3. **Concurrent writers.** Belief writes come from request threads *and* from
   the gossip timer. `docs/EMULATOR.md` describes the per-profile version
   counter that narrows this window and admits it does not close it. Per-NPC
   single-writer — the gossip tick owns all belief writes, and route threads
   post *intents* to it — is cleaner than a counter here, and costs nothing,
   because nothing needs a belief write to be synchronous.

Determinism proper: gossip, decay, deception, retrieval ordering and tool
validation are all pure functions of stored state and seeded RNG, in the house
style of `emu/rand` and `emu/ids` ("there is no global entropy anywhere in this
emulator"). Given the same event log they produce the same belief stores. The
model's temperature does not enter the world state anywhere.

### 4.4 Which model, run where, and the offline story

**Default: no model.** `npc.llm.enabled` defaults to `false` and the whole game
works. Same habit as the emulator serving valid empty tables with no database
present: "a server that only works with a 40MB item table present cannot be
started for the first time, cannot be tested, and greets a new user with a wall
of errors."

**When enabled: a local OpenAI-compatible endpoint on 127.0.0.1.** llama.cpp's
`llama-server`, Ollama, LM Studio — any of them, configured by URL, because
picking one is picking a dependency this project does not need. Loopback makes
the offline story trivial: no internet, no API key, no telemetry, and no part of
the player's profile leaves the machine. If a user points the URL at a remote
provider that is their decision; **nothing in the design assumes it and nothing
degrades without it.**

**Size.** The binding constraint is not quality, it is that Tarkov is already
using the GPU. Two honest options:

- **Out-of-raid only** — generation permitted in the hideout and the menu,
  refused in raid. This is nearly free, because the mailbox conversation
  *happens* out of raid. A 7-12B instruct model at Q4 fits in the VRAM a
  minimised Tarkov leaves behind, and 1-3 s is invisible on a mail channel.
- **CPU-only, always** — a 3-4B model on CPU threads, 5-15 s, never contending
  with the game at all. Slower, and completely safe.

Both are configuration, not architecture. The one thing the architecture must
not do is assume a dedicated GPU.

### 4.5 What is impossible or not reachable from this repo today

Stated plainly, because the brief asked for it:

- **Driving an NPC's *actions* is not reachable in the form this brief
  implies.** The reachable action vocabulary is `mods/sain`'s five driving calls
  plus four self-actions, all signature-gated, and **none of them has ever been
  executed against BSG's client** (`mods/sain/README.md` §4). There is no call
  to hand over an item, open a container, follow the player, or perform any
  social action. An LLM emitting `go_to(chest_41)` could at best become a
  `Mover.GoToPoint` — into an unproven surface, on a bot with no persistent
  identity.
- **In-world speech is not reachable.** No TTS in the tree, no way to attach a
  subtitle or a nameplate to a bot, and a bot's voice is a template id fixed at
  generation time (`emu/bots.nim`, `Customization.Voice`).
- **Persistent bot identity does not exist.** `emu/bots` generates throwaway
  profiles per raid from `bots.types.<role>`. A named, remembering, in-raid NPC
  requires inventing identity, spawn control and persistence first.
- **Witnessing is blocked on `docs/API-GAPS.md` gap 1.** `tarkov.raid.ended`
  carries `{"profile": id}` and nothing else (`tarkov.nim:1020`, `:1120`). No
  location, no survival flag, no exfil, no victim list. Subscribers currently
  reconstruct the location by pairing against `tarkov.raid.configured`, and
  `mods/pathtotarkov` has a single-slot pending state that breaks with two
  profiles in flight. Almost everything an NPC could witness about a raid is on
  the far side of that payload.
- **The player→NPC text channel is unverified** (§4.1).
- **Unknown, and only one raid away from being known:** whether the post-1.0
  client renders a mail message from an arbitrary sender id that is not a
  trader; whether it renders a message with no attachments and a long body;
  whether it will show a "typing" state at all. All three are cosmetic, and all
  three change how the conversation feels.

So the honest scope of v1: **NPCs are minds that gossip, remember, misremember,
lie, trade and write letters. They are not bodies.** Every part of §2 is
buildable today. Most of §3 is buildable today. §4.1 decides whether the player
can talk back, and none of the in-world action surface is available at any price
this repo can currently pay.

---

## 5. What would have to be built first

In order. Each step is testable with no model and no client, which is the
property that makes the order worth following.

### 5.1 Close API-GAPS gap 1 — `tarkov.raid.ended` says who and nothing else

One broadcast payload in `mods/tarkov/tarkov.nim` at two call sites, no ABI
change, already argued for in `docs/API-GAPS.md`. It needs to carry the
location, survival, the exfil taken and the victim list. Without it there is
nothing for an NPC to witness about the thing the game is mostly made of.
`mods/pathtotarkov` and `mods/icebreaker` both want the same edit for their own
reasons, so it pays for itself twice over.

### 5.2 The knowledge core, with no model at all

`mods/timbuktu/know/` — types, the store, the four indices, decay, the stance
computation, the deception table, the gossip pass. Pure nimony, no game calls,
no network, in the shape of `mods/sain/core/`. Plus a `selfCheck` in the shape
of `emu/dialogue.selfCheckDialogue` and `sain/core/selftest.nim`: inject a lie
at A, run two gossip hops, assert C's belief carries `contradicts`, the
predicted confidence band, and a `root` chain back to the fabrication. Assert
that decay of a `market` belief across a simulated week matches the closed form.
Assert that two contradictory beliefs both survive a save/load round trip and
that the stance picks the same one both times.

**This step is the pillar.** Everything after it is presentation.

### 5.3 The event→belief rule table

The bridge from `emu/*` events into layer 0 and layer 1. Small, declarative, one
row per event kind naming its witnesses. Testable against a scripted event log.

### 5.4 Settle the channel

Serve the send route against a live client and find out (§4.1). This is one
raid's worth of work and it decides the shape of everything player-facing. It
should happen before any prompt is written, not after.

### 5.5 `llmfetch.nim`

`mods/manager/mgr/httpfetch.nim` generalised: POST, a request body, a longer
deadline, the same C-worker / abandonment / `LoadLibrary` discipline verbatim.
It should live somewhere shared rather than being copied, and the copy that
exists should probably be refactored into it — but that is a decision for
whoever owns `mods/manager`, not this document.

### 5.6 The tool gate

Over the emulator procs that already exist. Testable with hand-written tool
calls and no model: assert that a call naming a non-existent template is
refused; that a call citing a belief handle absent from the prompt is refused;
that `offer_trade` beyond the persona's price band is refused; and that a
refusal is a typed value the conversation can continue from.

### 5.7 The prompt

Last. By this point the belief store, the retrieval, the tool gate and the
transport all exist and are tested, and writing the prompt is an evening's work
that can be iterated on without touching anything else.

---

## 6. The decisions that are the owner's, not mine

Six places where I made a call that is genuinely a matter of taste, or of what
the game is supposed to be, and where a different call is defensible:

1. **NPCs as correspondents, not bodies.** I scoped in-world NPC behaviour out
   entirely, on the evidence in `mods/sain/README.md`. If the project's whole
   point is talking to a character standing in front of you, this scope is wrong
   — but then the first task is proving one of SAIN's driving calls against the
   real client, not designing a knowledge system.

2. **No embeddings.** I chose an exact entity-graph index over vector retrieval,
   for testability and for not shipping a second model. If the project is
   willing to carry an embedding model, semantic retrieval over conversation
   history (not over beliefs) would genuinely help.

3. **The server lies, not the model.** Deception is a table and a seeded RNG.
   That buys determinism, traceability and testability, and costs surprise. A
   design where the model improvises its deceptions is more alive and is not
   reproducible across a save/load.

4. **Predicates are a closed vocabulary of about twenty-four.** This is the
   hardest constraint in the design and the one most likely to chafe. Everything
   an NPC can know has to fit it. The alternative — free-text propositions —
   makes contradiction detection, gossip mutation and tool gating all
   impossible, so I would defend it; but it does mean the world's *kinds* of
   knowledge are finite and authored.

5. **Default off.** The whole system runs with no model. Someone might
   reasonably prefer to require a model and design for a world where it is
   always there.

6. **Belief store size: 512 hot / 256 cold per NPC.** A guess. The right number
   comes from measuring, in the style of the mailbox soak.

---

## 7. Files this document was written against

Read in full or in substantial part: `mods/tarkov/emu/dialogue.nim`,
`mods/tarkov/emu/mail.nim`, `mods/tarkov/emu/notify.nim`,
`mods/tarkov/emu/store.nim`, `mods/tarkov/emu/sessions.nim`,
`mods/tarkov/emu/bots.nim` (head), `mods/tarkov/emu/quests.nim` (head),
`mods/tarkov/emu/traders.nim`, `mods/tarkov/emu/trading.nim`,
`aowl/src/aowlspt/server.nim`, `aowl/src/aowlspt/game.nim`,
`aowl/src/aowlspt.nim`, `backend/jsondb.nim`, `host/common/modstore.nim`,
`mods/manager/mgr/httpfetch.nim`, `mods/sain/sain.nim`,
`mods/sain/client/bridge.nim`, `mods/sain/README.md`, `abi/aowlspt_abi.h`,
`abi/aowlspt_net.h`, `docs/EMULATOR.md`, `docs/EMULATOR-REFUSALS.md`,
`docs/API-GAPS.md`, `docs/IL2CPP.md`, `reference/spt-4.1-surface.txt`.

No file in this repository was modified other than this one, and nothing was
built.
