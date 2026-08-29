# Co-op & general multiplayer — feasibility and phased design

Status: **scoping only. No feature code exists.** This document is the go/no-go
and the plan, written after reading the backend, the tarkov emulator, the
websocket transport and the client-side mods (`sain`, `morebots`, `maps`). It
separates what is achievable on this host now from what is Fika-scale and what
may be infeasible without BSG's own netcode. Evidence is cited to file:line.

The ask, restated once so the two layers stay distinct:

1. **A general multiplayer-backend capability** — plumbing many clients connect
   to: session/lobby management, join/leave, roster, a state-sync channel.
   Infrastructure other mods build server features on. Design it as a
   capability/API, not a finished game mode.
2. **`mods/tarkov` (the SPT emulator) acting as CO-OP** — the existing offline
   SPT raid becomes a small shared PvE raid for a few friends against the
   emulated bots, riding layer 1. Not a general PvP server.

---

## 0. TL;DR verdict

| Capability | Verdict | Why |
|---|---|---|
| Multiple clients → one backend, each with its own profile/session | **Already works** | `emu/sessions.nim` is a multi-entry session→profile map; the TLS server on 443 serves any number of connections. |
| Lobby / roster / join-leave / shared-session API | **Feasible now, backend-only** | New routes + the existing per-session websocket notifier. No IL2CPP. |
| Shared raid **seed** (all players get the same map/loot/bot layout) | **Feasible now, backend-only** | `match/local/start` already builds the map from a seeded `raidId`; make the seed lobby-scoped. |
| Shared **quest / loot / progression** state across the party | **Feasible, backend work** | All state is server-side read-modify-write over the profile document. |
| **Teammate position markers** on the map/minimap (see each other as dots) | **Feasible, medium** | `mods/maps` already reads the alive-player list and renders per-contact markers client-side; feed it teammate positions over the sync channel. |
| **Rendering a second real player in the 3D world** (moving, shooting, hittable) | **INFEASIBLE phase-1; Fika-scale, high-risk** | Requires a game-net transport we control, IL2CPP instantiation of `ObservedPlayer`, and per-frame movement/animation replication. The host has *never* instantiated a managed game object — it only reads. Every step is by-name / unmeasured-RVA territory (fatal when used, facts #145/#198). |

**Bottom line.** A convincing *co-op experience* is reachable without touching
BSG's netcode: same raid, shared objectives and loot, and seeing your friends as
markers. **In-world player-model replication is a separate, much larger project**
and should not be promised as part of this increment. Say so plainly in any
user-facing copy.

---

## 1. How a raid works today (measured)

**One backend, many sessions already.** `emu/sessions.nim` stores a `seq` of
`{session, profile, raidLocation, raidMode}` bindings, persisted
(`sessions.nim:43-107`). `boundSessions` sweeps every session
(`sessions.nim:109-118`). Nothing about the request path assumes a single
player — the client's `PHPSESSID` cookie selects the binding per request. This is
the single most important feasibility fact: **the lobby layer does not need a new
session concept, only a grouping over the one that exists.**

**Raid entry is a pure request/response against the emulated server.** The flow
(routes in `tarkov.nim:3151-3207`):

- `/client/raid/configuration` → `onRaidConfiguration` sets `gRaidId`,
  `gRaidClock`, remembers the map on the session, builds the ORBIT bot plan
  (`tarkov.nim:2082-2106`).
- `/client/match/local/start` → `onMatchStart` returns the **whole map**:
  `{serverId, serverSettings, profile, locationLoot, transition,
  excludedBosses}`, where `locationLoot` is laid out from the `raidId` **seed**
  (`tarkov.nim:2119-2201`, esp. `localLoot(startLocation, nowSeconds(), raidId)`
  at 2191). Same seed ⇒ same map/loot/bot layout.
- `/client/game/bot/generate` → `onBotGenerate` (`tarkov.nim:2634`, logic in
  `emu/bots.nim`): the client asks for AI profiles and **the client's own game
  code instantiates them**. The server never spawns anything in the world.
- `/client/match/local/end` → `onMatchEnd`: posts the whole profile; results,
  `transferItems`, insurance are applied server-side.

**Bots are 100% client-instantiated from server data.** `mods/morebots`
documents its client half as writing *nothing* into the game — "On the client,
nothing… read-only by design" (`morebots.nim:35-38`). The server writes spawn
tables/caps into the shared DB; the client's native spawner honours them. This is
the SPT model and it is the template for how a second human could — but does
**not** — appear: there is no "instantiate a player" path anywhere in the host.

---

## 2. The transport we already control

**A per-session WebSocket notifier exists and is bidirectional-capable.**
`backend/websocket.nim`:

- Server→client push: `wsPush(session, payload)` (`websocket.nim:277-289`),
  fronted by `notify_push` rev-5 (`aowlbackend.nim:1094-1103`) and the mod-side
  `notifyOrQueue` with a durable fallback queue (`emu/notify.nim:73-109`).
- Client→server: `wsOnMessage` **already reassembles whole inbound frames**
  across continuations and currently just logs+ignores them
  (`websocket.nim:394-407`). The receive plumbing is done; only a dispatch is
  missing.
- Liveness: ping/idle reaping (`websocket.nim:409-423`), forget-on-gone
  (`websocket.nim:425-433`), roster count `wsOpenCount` (`262-265`).

**Caveat — the game never sends on this socket.** The notifier is a native EFT
feature that only *receives* server pushes. So `wsOnMessage` will only ever fire
for a message some code we control causes the client to send — i.e. it is usable
as a client→server channel **only if a host detour or a client-side aowlspt mod
originates the frame.** For phase-1 co-op, the client→server direction of
gameplay state (a player's own position) has to come from an aowlspt client mod
reading the local player and posting it, *not* from the stock game.

**The mod event bus** (`aowlspt/server.nim`: `broadcast`/`emit` at 755-764,
consumed via subscribe in the host) already relays `tarkov.raid.started`,
`tarkov.raid.configured`, `tarkov.raid.ended` (`tarkov.nim:2099,2160,2316`).
This is the intra-process fan-out that a sync-channel consumer plugs into.

---

## 3. The client-side wall, stated honestly

To render a second real player, three things must all exist. None do:

1. **A game-network transport feeding the world.** Real EFT gets remote players
   over BSG's UDP game channel (separate from this HTTP backend). SPT offline has
   zero remote players. We would have to run our own real-time transport (UDP or
   the notifier WS repurposed) *and* map its packets onto game state.
2. **Instantiating an `ObservedPlayer` in IL2CPP.** The host today only *reads*
   players: it borrows the `GameWorld` from a read-only detour on
   `GameWorld::RegisterPlayer` (`sain/client/live.nim:172-177`) and walks
   `AllAlivePlayersList@0x1c8` as a plain `List<Player>`
   (`live.nim:2003-2032`, fact #226, measured live). **It has never constructed a
   managed object.** Doing so needs `object_new` + the correct `Il2CppClass` +
   a real constructor call + `RegisterPlayer` — every one a by-name/unmeasured
   path, and by-name IL2CPP is **fatal the moment it is USED**, not when resolved
   (facts #145/#198; `il2cpp-by-name-is-fatal-when-used`). Constructing a valid
   `Il2CppClass` is explicitly *unverified* (CLAUDE.md §5).
3. **Per-frame replication** of position/rotation/animation/weapon/health for
   every remote player, on the Unity main thread, under the one-guard-per-body
   rule (CLAUDE.md §5). This is the bulk of Fika, and Fika had BepInEx + Harmony
   + Reflection, none of which exist here (`sain.nim` header: "64,000 lines of C#
   built on BepInEx, Harmony and BigBrain cannot be transliterated").

**Verdict:** in-world player replication is a **separate multi-month project**
with a large unmeasured-RVA surface and a high crash risk. It is out of scope for
this increment. If it is ever attempted, it is its own design doc with its own
RVA measurement campaign, not a phase of this one.

**What reaches "co-op feel" without that wall:** `mods/maps` already renders a
marker per contact from the alive-player list and ships a "Show players" toggle
(`maps.nim:232`, ESP draw region note at `maps.nim:46`). Teammate **markers** on
the map/minimap are therefore a feed-the-existing-renderer problem, not a
new-IL2CPP problem.

---

## 4. Layer 1 — the general multiplayer-backend API

Design it as a **capability other mods consume**, living in the backend/server
library, not as game logic. Keep it game-agnostic: it knows about *sessions*,
*lobbies* and *opaque state channels*, never about raids or Tarkov.

### 4.1 Concepts

- **Session** — already exists (a `PHPSESSID` ⇄ identity). Reused as-is.
- **Lobby** — a named group of sessions with an owner, a capacity, a `state`
  (`open` / `locked` / `in-session` / `closed`) and an opaque
  `mode` string (Tarkov co-op supplies `"raid"`; other mods supply their own).
- **Roster** — the members of a lobby, each `{session, profile, displayName,
  ready, present}`. `present` is driven by notifier liveness (`wsOpenCount`
  semantics), so a crashed client leaves rather than wedges the lobby.
- **State-sync channel** — a per-lobby ordered pub/sub of opaque JSON messages.
  The backend does **not** interpret payloads; it fans them out to every other
  member and (optionally) retains a last-value per key for late joiners.

### 4.2 Routes (proposed, all under a neutral prefix so it is not Tarkov-specific)

```
POST /aowl/mp/lobby/create      {mode, capacity, name?}      -> {lobbyId, owner}
POST /aowl/mp/lobby/join        {lobbyId}                     -> {roster}
POST /aowl/mp/lobby/leave       {lobbyId}                     -> ok
POST /aowl/mp/lobby/list        {mode?}                       -> [{lobbyId,name,mode,count,capacity,state}]
POST /aowl/mp/lobby/roster      {lobbyId}                     -> {roster, state}
POST /aowl/mp/lobby/ready       {lobbyId, ready:bool}         -> {roster}
POST /aowl/mp/lobby/set         {lobbyId, state}              -> ok    (owner only)
POST /aowl/mp/sync/publish      {lobbyId, key?, payload}      -> ok
      # inbound sync also accepted over the notifier WS (see 4.3)
```

Fan-out (server→client) rides the **existing notifier** `wsPush` per member
session (`websocket.nim:277`), with the durable queue fallback
(`notify.nim:73`) so a member with a momentarily closed socket still gets roster
deltas. Message envelope: `{"type":"mp.roster"|"mp.sync"|"mp.lobby", ...}` so a
consuming mod filters by `type` off the one notifier stream it already reads.

### 4.3 The sync channel, both directions

- **Down:** `wsPush` to each member. Ordered per-connection by TCP; the backend
  stamps a monotonic `seq` per lobby so a consumer can detect a gap.
- **Up:** extend `wsOnMessage` (`websocket.nim:394`) to parse a small framed
  envelope and dispatch `mp.sync` to the lobby fan-out. **This only works when an
  aowlspt client-side mod originates the frame** (§2 caveat) — the stock game
  will not. For phase-1 that originator is a small client mod reading the local
  player's transform; there is no stock-game up-channel.
- **Retention:** optional last-value-per-key (`key` in `publish`) so a late
  joiner is handed current state (e.g. "current raid seed", "objective X done")
  on join rather than waiting for the next delta.

### 4.4 What layer 1 deliberately does NOT do

No gameplay semantics, no anti-cheat, no authority arbitration, no real-time
(sub-100ms) guarantees. It is a lobby + a reliable-ish JSON pub/sub. A mod
wanting a 60 Hz authoritative server builds that on top (and will likely want a
UDP side-channel layer 1 does not provide — call that out to the user).

---

## 5. Layer 2 — `mods/tarkov` as co-op

Co-op is a **thin consumer** of layer 1. The SPT raid becomes a *shared PvE
session*: same world, shared objectives/economy, friends visible as markers.

### 5.1 What syncs, and when it is realistic

| State | Mechanism | Phase |
|---|---|---|
| **Raid seed** (map, loot layout, bot waves) | Lobby owner's `raidId` becomes the lobby seed; every member's `match/local/start` uses it, so `localLoot(loc, ts, seed)` lays out identical worlds (`tarkov.nim:2191`). | **1** |
| **Membership / who is in the raid** | Roster + `raid.started`/`raid.ended` broadcasts (`tarkov.nim:2160,2316`) scoped to the lobby. | **1** |
| **Teammate position markers** | Client mod reads local player transform (same read path `sain`/`maps` use), publishes over sync-up; peers render via the existing `maps` "Show players" marker path (`maps.nim:232`). | **2** |
| **Quest / objective progress** | Server-side; on any member's quest-condition update, fan out and (co-op rule) credit the party. All quest state is already server RMW (`emu/questcond.nim`, `quests.nim`). | **2** |
| **Loot / container / door state** | Server-authoritative shared world state keyed by lobby seed; publish deltas so a looted container shows empty for all. Larger; needs a shared per-raid world-state store the emulator does not have yet. | **3** |
| **Bot state / AI authority** | One member is bot-authority (bots are client-instantiated per client today, so naive co-op gives each player *their own* copy of the AI). True shared bots need either server-authoritative bot transforms (Fika-scale) or accepting per-client bots in phase 1. | **3 / maybe never** |
| **In-world player models** (see each other move/shoot) | §3 wall. | **out of scope** |

### 5.2 The honest co-op that phase 1+2 delivers

Friends launch into the **same map with the same loot and bots**, share quest and
economy progress, and **see each other as markers** on the map/minimap — but each
runs their own instance of the bots and does not see the other's body in the 3D
world. This is "shared PvE session + squad map awareness", which is a real and
useful co-op mode, and it is honest about not being Fika.

---

## 6. Phasing, each with a falsifiable check (CLAUDE.md §9b)

A check must be able to FAIL. Prefer negatives. Three outcomes: PASS / FAIL /
INCONCLUSIVE.

**Phase 0 — spike, backend only (no game).**
Lobby create/join/leave/roster + sync publish/fan-out, exercised by `emutest`
with two synthetic sessions.
*Check (negative):* start two sessions, one publishes key `k=1`; assert the
**other** session's notifier queue contains exactly that message and the
publisher's does **not** (no echo). A test that only asserts "publish returned
ok" is the §9b anti-pattern and is rejected. INCONCLUSIVE if either socket never
opened.

**Phase 1 — shared raid seed + roster, two real clients.**
Lobby owner's seed drives both clients' `match/local/start`.
*Check (negative):* diff the two served `locationLoot` documents for identical
loot spawn ids/positions; FAIL if any spawn differs. Cross-check that a
**non-lobby** client on the same map gets a **different** layout (proves the seed,
not a constant, is doing the work).

**Phase 2 — teammate markers + shared quest credit.**
Client mod publishes local position; peer renders a marker; a quest condition
completed by one credits both.
*Check (marker):* via the live inspector, read the peer's marker object under the
maps overlay and assert its world position tracks the mover within tolerance;
INCONCLUSIVE if the overlay node is not found (do not report PASS).
*Check (quest, negative):* member A completes condition C; assert member B's
served profile shows C progressed AND a control member **outside** the lobby does
**not**.

**Phase 3 — shared world-state (loot/doors), bot authority.**
Deferred; own design pass. Do not start before phase 2 verifies.

**Out of scope — in-world player replication.** Separate project, separate RVA
campaign. Not a phase here.

---

## 7. IL2CPP / by-name hazards and unmeasured RVAs to flag

Anything client-side in this plan must obey CLAUDE.md §5 and the
`il2cpp-by-name-is-fatal-when-used` rule. Specifically:

- **No new by-name lookups.** Reading the local player's position for the marker
  feed must reuse the **already-measured** read paths (`sain/client/live.nim`
  `RegisterPlayer` world-borrow + `AllAlivePlayersList@0x1c8`, fact #226) — not a
  fresh by-name resolve. A by-name handle passes a nil check and kills the client
  on first use (facts #35/#145/#198).
- **No second detour on `RegisterPlayer`.** Ride the host's existing read-only
  detour (`live.nim:172-177`); a second detour overwrites the first's trampoline
  (CLAUDE.md §5). Position reads for teammates are plain guarded field reads off
  the borrowed world — no new patch.
- **`ObservedPlayer` construction is UNMEASURED and unverified** — the whole §3
  wall. If phase-3+ ever attempts it: `object_new`, the player `Il2CppClass`, the
  constructor RVA, `RegisterPlayer` as a *write*, and every per-frame setter
  (position/rotation/animator) are **all** unmeasured and must be byte-verified +
  sharedness-checked (`il2cpp_resolve.py ... shared`) before any call. None exist
  today.
- **The sync-up channel needs a client originator.** `wsOnMessage` receiving is
  ready (`websocket.nim:394`) but the stock game never sends; the phase-2
  position publisher is a new client-side aowlspt mod, and its only game contact
  is the *read* above.
- **Bot instantiation stays client-side.** Do not try to server-spawn bots into
  the world; that is not how any of this works today (`morebots.nim:35-38`).

---

## 8. Open questions for the human (decisions, not derivations)

1. **Transport for real-time position:** repurpose the notifier WS (simple,
   reliable, ~notifier latency) vs. a new UDP side-channel (lower latency, more
   work). Phase-2 markers tolerate the WS; twitch replication would not — and
   replication is out of scope anyway. Recommend WS for now.
2. **Quest co-op rule:** credit-the-party vs. per-player objectives. Affects
   phase-2 economy balance.
3. **Bot authority in shared raids:** accept per-client bots (each player fights
   their own copies) for phase 1, or block co-op until shared bots exist?
   Per-client is the only cheap option and is the honest phase-1 answer.
4. **Where layer-1 lives:** `aowl/src/aowlspt/server.nim` as a reusable capability
   (recommended — matches "other mods build on it") vs. a standalone `mods/mp`.
</content>
