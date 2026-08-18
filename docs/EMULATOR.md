# The emulator

`mods/tarkov` is a Tarkov server — profiles, the static tables, traders, the
inventory, raids — and it is **a mod**. It imports `aowlspt` and
`aowlspt/server` and nothing else. There is no private door into the host.

That constraint is the reason it exists in this repo. A plugin API is only as
good as the largest thing anyone has written with it, and the largest thing
worth writing here is the game server itself. Every gap found while writing it
was closed in the API rather than worked around in the mod:

| Found writing | Closed by |
|---|---|
| profiles must survive a restart | `save` / `load` / `savedKeys`, on ABI revision 2 |
| every route reads a request body | `aowlspt/json` — `field`, `each`, `count` |
| every route writes one back | `arr`, `objOf`, `envelope`, `failure` |
| a profile must keep fields the mod does not model | `Doc` / `List` member-wise editing |
| one mod tells another a raid ended | `broadcast` / `onEvent`, now delivered |

```
aowl build-mod mods/tarkov
```

## Writing an endpoint

```nim
proc onKeepAlive(url, body, session: string): string =
  var o = obj()
  put(o, "msg", "OK")
  put(o, "utc_time", nowSeconds())
  result = envelope(o)

discard serve("/client/game/keepalive", onKeepAlive)
```

`envelope` is not optional. Every `/client/*` endpoint answers
`{"err":0,"errmsg":null,"data":...}`, and the client reads `err` before it looks
at anything else — a route returning bare data gets a client that treats a
perfectly good response as a failure, with a 200 on both sides and nothing in
either log.

## What is implemented

| | |
|---|---|
| **Login** | config, start, version validate, keepalive, logout, server list |
| **Profiles** | list, create, select, nickname validate/change, persistence |
| **Static tables** | items, globals, handbook, customization, locales, languages, settings, quests, achievements |
| **Inventory** | move, split, merge, transfer, remove, fold, toggle, tag, swap, examine |
| **Traders** | settings, assorts, per-trader prices |
| **Raids** | configuration, local loot, weather, match start, **match end** |
| **Menu** | notifier channel, mail, friends, builds, flea market, insurance, hideout tables |

The profile is held **as JSON text** and edited member-wise. A typed model would
have to name several hundred fields to avoid dropping any — and the day the
client adds one, a typed model silently deletes it from every profile it saves.
Text plus a merge keeps what it does not know about.

## What comes out of the database, and what happens without one

Every static table is a `dbRead` with a fallback. A server started with a live
database dump serves the real items, traders and locales; a server started with
nothing serves valid empty tables — and the client still reaches its menu,
creates a profile, and enters a raid.

That is deliberate, and it is what makes the emulator testable at all. A server
that only works with a 40MB item table present cannot be started for the first
time, cannot be tested, and greets a new user with a wall of errors.

One consequence is worth naming: `itemStackLimit` returns **zero for "unknown"**,
not one. Treating an unknown template as a stack limit of one makes every merge
fail on a server with no item table — which was a real bug, caught by the test
below, and fixed by making "I don't know" a different answer from "one".

## Testing

```
aowl test
```

runs `emutest`, which drives the client's boot sequence over the wire — zlib
framing included — in the order the client uses it:

```
ok    game config
ok    no profiles on a fresh install
ok    create returns a profile id
ok    the duplicate nickname is refused
ok    select binds the session
ok    split reports the new stack
ok    merge deletes the source
ok    and the encyclopedia remembers it
ok    a move of an item that is not there is a warning, not a 500
ok    the raid result is accepted
ok    a raid result for another profile is refused
```

Two of those checks carry more weight than the rest.

**Order.** These endpoints depend on each other. Tested individually they would
pass against a server that cannot actually get a player into the menu.

**The restart.** Halfway through, `emutest` kills the backend and starts it
again against the same root. Everything after that point runs against a server
that has forgotten everything except what it wrote to disk — which is the only
way to tell a working profile store from a working in-memory cache.

## What it is not

It does not have the game's content. Traders sell what the database gives them,
maps have the loot the database has, quests are the quests in the database. Bot
generation, the flea market's economy, hideout production and insurance returns
are endpoints that answer correctly and do nothing interesting yet.

The distinction that matters: those are *content*, and they belong in mods —
including in this one. The pipeline underneath them is finished and tested.
