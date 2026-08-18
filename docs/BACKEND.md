# The backend

`aowlspt-backend` is the server half of the pipeline: an HTTP server in nimony
that loads the same mods, built the same way, with `aowlspt/server` where the
client has `aowlspt/game`.

```
aowlspt-backend --root D:\Aowlspt --port 6969
aowlspt-backend --root D:\Aowlspt --selftest      # drive every route, then exit
```

## Why not SPT's server

SPT 4.x targets `0.16.9.40743` — a pre-1.0 client. Building on it would mean
either waiting for someone else's server to cross the 1.0 line or crossing it
backwards ourselves, and the second is the thing this project refuses to do.

Owning the backend also collapses the pipeline into one thing: the backend and
the client host share an ABI, a mod format, a build command and a test gate. One
`.dll` serves both sides with a `side()` guard.

## The emulator

There **is** a Tarkov server on this now, and it is a mod like any other:
`mods/tarkov`, documented in [EMULATOR.md](EMULATOR.md). It imports `aowlspt`
and `aowlspt/server` and nothing else — which is the only honest test of whether
this API is enough to build a game server with.

## What the backend itself is not

The backend is not the game. Serving the game's several hundred
endpoints with correct data is an order of magnitude more work than this, and it
belongs in mods rather than in the server. What is here is the pipeline —
sockets, the client's wire framing, routing, a database, the mod ABI, and the
plugin API on top. What runs on it is content.

## Writing a backend mod

```nim
import aowlspt
import aowlspt/server

proc onStatus(url, body, session: string): string =
  var o = obj()
  put(o, "ok", true)
  put(o, "players", 1)
  result = done(o).text

proc onLoad(): Status =
  discard serve("/aowlspt/status", onStatus)
  discard servePrefix("/aowlspt/item/", onItem)   # ids come out of the path

  # A merge, not a replace
  discard dbWrite("templates.items.5447a9cd4bdc2dbd208b4567",
                  """{"_props":{"Weight":0.5}}""")
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideServer}, onLoad = onLoad)
```

`examples/gameserver` is that, complete and tested.

| | |
|---|---|
| `serve(url, handler)` | exact-match route |
| `servePrefix(prefix, handler)` | prefix route; `pathAfter(url, prefix)` for the rest |
| `dbRead(path)` | `.asText()`, `.asFloat()`, `.asInt()` |
| `dbWrite(path, patch)` | **merges** into the object at `path`, creating it if it is not there |
| `setting(key)` | this mod's `config.json` — `.asText()`, `.asInt()`, `.asFloat()`, `.asBool()` |
| `obj()` / `put` / `arr()` / `done` | JSON, with escaping you cannot forget |
| `envelope(data)` | the client's `{"err":0,...}` wrapper — not optional |
| `save(key, value)` / `load(key)` / `savedKeys(prefix)` | this mod's own persistent store |
| `broadcast(name, payload)` / `onEvent(name, handler)` | between mods, delivered synchronously |
| `afterMs(delay, handler)` / `everyMs(interval, handler)` | run something later, or repeatedly, off the request threads |
| `field(body, "a.b[0].c")` | reading a request body — `aowlspt/json` |

`everyMs` re-arms *after* the handler returns, not on a fixed schedule, so a
sweep that takes longer than its interval falls behind rather than overlapping
itself. That is what a periodic sweep — expiring flea offers, posting insurance
returns — wants, and it is the only version a handler that assumes it runs alone
can survive.

**`setting(...).asText()` strips the quotes, on every host.** It did not, and
the hosts disagreed: the backend and the client host strip them on the way out,
the C# simulator hands back the raw JSON literal. So `setting("edition")` was
`standard` on a server and `"standard"` in the simulator — an empty string
setting had length two, and a value used to build a database path addressed
nothing on one side while working on the other. Two mods had grown their own
private unquoting helper by the time it was noticed, which is the shape of a
missing library function. Stripping in `ConfigValue.asText` rather than in each
host is what makes it true everywhere, including on a host written later.

## The wire protocol

Two details that a server gets wrong exactly once.

**Bodies are zlib-framed both ways.** The client compresses every request body
and expects a compressed response. A server that answers plain JSON gets a
client that fails to parse it, with a 200 on both sides and nothing in either
log. This is why `curl` cannot tell a working route from a broken one, and why
`aowlprobe` exists:

```
aowlprobe http://127.0.0.1:6969/aowlspt/status --expect '"ok":true'
```

Unframed *requests* are still accepted — the tools people debug with do not
compress, and refusing them would make the server untestable by hand. The check
is the two-byte zlib header, not a guess.

**The session id is a 24-character hex MongoId.** Anything else is rejected
before a route sees it, so a malformed id is not reported as some mod's bug.

## Merging, and why it matters

`dbWrite` merges recursively, and **creates a path that is not there**. Refusing
a missing path is right for a patch and wrong for a mod whose job is adding
content — a new location, a new bot type, its own table — which made the
ordinary case inexpressible and had every such mod carrying the same workaround.
 Two mods editing sibling fields of the same item
do not clobber each other — that is the difference between a mod system and a
pile of mods that happen to coexist. The test asserts it both ways:

```
ok     weight 0.38 -> 0.19
ok     the sibling field survived the patch: M4A1
```

The document is held as text and edited as text. That sounds wrong and is
deliberate: a parsed tree needs a mutable dynamic value type nimony does not
give cheaply. What it guarantees is that a patch which cannot be applied
*exactly* is refused rather than applied approximately.

Text alone was not enough, though. Each object is indexed the first time
something addresses it, so a lookup costs a hash lookup per path segment instead
of a walk from the document root — see [PERF-SERVER.md](PERF-SERVER.md). The
index is byte offsets into the document, so `dbWrite` throws all of it away.

## Shape of a run

- Loopback only, and there is no flag to change that. A single-player game
  server that listens on every interface by accident is how a LAN party becomes
  an incident.
- A fixed pool of accept threads (8 by default). Several threads may `accept`
  the same listening socket on Windows; the pool size is the concurrency limit
  and there is no per-request thread creation. It is the *connection* limit now
  rather than the request limit, which is why it is eight rather than four.
- Keep-alive, so a session is one connection rather than thousands. A
  connection is closed after 512 requests anyway, so no client can hold a
  worker for the life of the process.
- 15-second receive timeout on a request in flight, dropping to 5 seconds once
  a keep-alive connection goes idle between requests.
- The static tables are served out of a compressed-body cache keyed on the
  response text itself, so a stale hit is impossible by construction, and the
  database is indexed per object so a lookup is a hash lookup rather than a
  scan. The numbers and the reasoning are in [PERF-SERVER.md](PERF-SERVER.md).

## Testing

```
aowl test
```

includes `--selftest`: the server comes up on its own port, drives every route
through the same wire code `aowlprobe` uses, and exits with the result.

```
ok    status route
ok    body survives the round trip
ok    prefix route reads the database
ok    unknown routes 404
ok    a mod can create a database path that was not there
ok    an uncompressed body is accepted too
ok    a malformed session id is refused
```

One command, no orchestration, and it tests the framing rather than trusting it.

## What a backend mod does not get

| | |
|---|---|
| `resolve` / `call` | client-side; there is no managed runtime here to reflect into |
| `patch` | client-side; there is no compiled game code here to detour |
| nothing else | events, timers and the store all work here |

`invoke_main` runs the callback where it stands: routes already run on worker
threads, so there is no main thread a mod needs to be moved to.
