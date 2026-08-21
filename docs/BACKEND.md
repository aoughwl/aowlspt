# The backend

`aowlspt-backend` is the server half of the pipeline: an HTTP server in nimony
that loads the same mods, built the same way, with `aowlspt/server` where the
client has `aowlspt/game`.

```
aowlspt-backend --root D:\Aowlspt --port 6969
aowlspt-backend --root D:\Aowlspt --selftest      # drive every route, then exit
aowlspt-backend --root D:\Aowlspt --perf          # per-phase timings, to <root>/perf.txt
aowlspt-backend --root D:\Aowlspt --store-flush   # force every store write to the medium
aowlspt-backend --root D:\Aowlspt --no-store-lock # start even if another backend holds the store
```

Both store flags are about durability and are explained under
[What survives a crash](#what-survives-a-crash); the defaults are the ones to
use.

`--perf` is the answer to "where inside a request did the time go" — inflate,
route match, the route itself, deflate, send, and nested under the route, the
`db_get` / `db_patch` / `store_get` / `store_set` calls the mod makes. It is off
by default and costs one branch per call site when it is. The breakdown is
written once a second as well as at exit, because a load generator kills the
server rather than asking it to stop. `benchbackend --perf` passes it through
and prints it; [PERF-SERVER.md](PERF-SERVER.md) is what it is for.

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
| `notifyPush(session, payload)` | push a notification down that session's websocket; `ErrNotFound` means there is none, which is normal |
| `afterMs(delay, handler)` / `everyMs(interval, handler)` | run something later, or repeatedly, off the request threads |
| `field(body, "a.b[0].c")` | reading a request body — `aowlspt/json` |

`everyMs` re-arms *after* the handler returns, not on a fixed schedule, so a
sweep that takes longer than its interval falls behind rather than overlapping
itself. That is what a periodic sweep — expiring flea offers, posting insurance
returns — wants, and it is the only version a handler that assumes it runs alone
can survive.

**`setting(...).asText()` strips the quotes, on every host.** It did not, and
the hosts disagreed: the backend and the client host stripped them on the way
out, the (then C#) simulator handed back the raw JSON literal. So `setting("edition")` was
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

## HTTPS, for the real client

A post-1.0 Escape From Tarkov client talks to its backend over **HTTPS on port
443** and *disables* certificate validation — so a self-signed certificate is
accepted, any CN. The default backend is plain HTTP (every test tool speaks that
and must keep working); `--tls` is what a real client needs.

```
aowlspt-backend --tls                 # HTTPS on 443, self-signed cert
aowlspt-backend --tls --port 8443     # a spare port, for testing
aowlspt-backend --gen-cert            # write the cert+key and exit
```

- **The certificate lives beside the backend**, as `aowlspt-tls-cert.pem` and
  `aowlspt-tls-key.pem` in `--root` (override with `--cert` / `--key`). It is
  generated with `openssl` on the first `--tls` run if it is not already there,
  so `openssl.exe` needs to be on `PATH` (or in the ucrt64 `bin`) for that one
  step; a run with the PEMs already present needs no openssl at all. `--gen-cert`
  is the explicit one-time step.
- **OpenSSL 3 is loaded at runtime**, not linked: `libssl-3-x64.dll` and
  `libcrypto-3-x64.dll` (from the msys2 ucrt64 toolchain) are found by name via
  `LoadLibraryA`, so a `--tls` build needs them **beside `aowlspt-backend.exe`
  or on `PATH`**. A plain-HTTP run never touches OpenSSL, and a `--tls` run that
  cannot find the DLLs says so rather than failing to start with no reason.
- **TLS is a transport shim only.** It terminates in `aowlspt_tls.h` /
  `aowlspt_net.h`, under the poller; everything above the byte stream — the zlib
  framing, the router, the database, the mod API — is unchanged, and all of
  `/client/*` is reachable, not one route. Test it with a client that skips
  verification the way the game does: `curl -k https://127.0.0.1:8443/...`.

## The asset port, and why it is not HTTPS

Under `--tls` the backend opens a **second listener, plain HTTP, on port 80**
(`--asset-port N`; `--asset-port 0` turns it off). It is the same server — same
routes, same router, same worker pool — reached over a socket that never
negotiates TLS.

It exists because of a client bug, not a preference. `/client/*` goes over the
client's *managed* HTTP stack, which post-1.0 configures to accept any
certificate; that is why the self-signed cert works. **Assets do not.** Every
`/files/*` fetch — trader avatars, quest and handbook icons, document images,
bundles — is a `UnityWebRequest`, through Unity's own transport, and the
client's call sites never assign a `certificateHandler`
(`EFT.<DownloadTexture2D>d__218::MoveNext`, RVA `0xA7FF70`; the request is built
at `+0xA8018F` with none). Unity therefore validates the certificate, rejects
it, and **never sends the request**. The error branch returns null *without
logging*, so the symptom is an icon that spins forever and a client log with
nothing in it; the only trace is a `handshake FATAL` line on the server side.

No server can make that client accept its certificate. So the asset base offers
none: the tarkov mod's `backend.Static` names `http://127.0.0.1`, this listener
answers it, and no handshake — and so no validation — ever happens. The other
five backend urls (`Main`, `Trading`, `Messaging`, `RagFair`, `Lobby`) stay on
HTTPS; they are the traffic that already works.

Port 80 is the default because a bare `http://127.0.0.1` names it, and a
portless url keeps clear of the client's host parsing. If something already
holds 80 (IIS, the Hyper-V/WinNAT reserved ranges), the backend says so and
carries on serving `/client/*`; move it with `--asset-port N` **and** move the
mod's `AssetUrl` to `http://127.0.0.1:N` to match — the client is given whatever
that constant says.

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
of a walk from the document root — see [PERF-SERVER.md](PERF-SERVER.md).

**A write costs the patch, not the document.** It used to cost the document:
`dbWrite` rebuilt the whole text and threw the index away, which is 171 ms for a
two-hundred-byte patch against a 41 MB database and 171 ms whatever the patch
says. The splice happens in the document's own buffer now, and the index
survives it — it is held in the coordinates the document had when it was last
built, with a short list of the regions patched since to translate through, and
every ambiguity in that translation falls back to rebuilding rather than to a
guess. Same patch, same database: 6 ms. Reads are untouched, which is the
constraint the design is shaped by; the numbers and the three cases that force a
rebuild are the last section of [PERF-SERVER.md](PERF-SERVER.md).

## Shape of a run

- Loopback only, and there is no flag to change that. A single-player game
  server that listens on every interface by accident is how a LAN party becomes
  an incident.
- **A poller and a pool of request workers.** One thread owns the listening
  socket and every connection that is not currently being answered; it waits in
  `WSAPoll`, accepts, and reads. A connection reaches one of the sixteen
  workers only when a *complete* request is buffered, and goes back to the
  poller when the answer has gone out. So the pool is the concurrency limit on
  answering — which is the only thing a thread was ever needed for — and not
  the number of connections the server can have.

  It used to be the second thing, and that was a denial of service: a worker
  was taken at `accept` and given back at `close`, keep-alive means a
  connection lives for a session, and twelve sockets that declared a body and
  never sent it shut every other client out. A connection that stalls,
  dribbles, or says nothing now costs a socket and the bytes it actually sent —
  about 7 KiB, and nothing at all until it sends something. The limits are 1024
  connections and 64 MiB of buffered request, in `abi/aowlspt_net.h`, which
  also records why that file uses `WSAPoll` rather than IOCP and what it gave
  up. `fuzzwire` holds 256 of them open and asks for a page: it arrives in
  0 ms.
- **A websocket, for the notifier.** A request carrying `Upgrade: websocket` is
  answered `101` and the connection is held by the poller for the rest of the
  session; a mod pushes to it with `notifyPush(session, payload)` and never
  learns a socket exists. That is possible *because* of the point above and was
  not before it: under a pool of accept threads a held connection took one of
  them for its life, so the emulator answered the same URL with a poll and said
  so in `mods/tarkov/emu/notify.nim`. The poll is still there and still answers
  every client that does not upgrade.

  The split is stated where it falls. `abi/aowlspt_net.h` owns frame
  *boundaries* and the read-path refusals — an unmasked client frame, a length
  over `AOWL_WS_MAX_FRAME` refused off the length field rather than allocated
  for, a control frame that is fragmented or too long. The handshake is
  `backend/websocket.nim`, because it is `Sec-WebSocket-Key` + the well-known
  GUID + SHA-1 + base64 and nimony ships both; so is every byte that goes out,
  which is the rule the rest of the server already keeps. `tools/wstest.nim` is
  the gate: it performs the handshake, provokes a notification through the
  game's own routes, and asserts the frame — plus the refusals, a client that
  vanishes without closing, and a hundred idle websockets held open while
  ordinary requests are timed behind them.

  **The poller never waits on the websocket write lock.** There is one lock for
  every websocket, a worker holds it across the `send` of a push, and the
  poller needs it for every pong and close it answers — so a poller that waited
  for it was one non-reading notifier client away from stopping the whole
  server: no accepts, no reads on any connection, no deadlines, for as long as
  that push took. It used to wait. Now a frame it cannot write is queued on the
  connection and goes out a few milliseconds later, and a close it cannot make
  is retried on the same clock; nothing is dropped for being unlucky with a
  lock. `tests/ws_stall.c` is the reproducer — it holds the lock with real
  pushes at a client that has stopped reading and times ordinary requests
  through the middle of it. It is not in `aowl test` yet (wiring it needs an
  edit to `tools/aowl.nim`); build and run it by hand:

  ```
  gcc -O1 -Iabi -o tests/ws_stall.exe tests/ws_stall.c -lws2_32 -lz
  tests/ws_stall.exe --port 7127
  ```

  Against the header before the fix it reports one ordinary request in a
  two-second window and no answer to it; after, eighteen, none slower than a
  millisecond.
- Keep-alive, so a session is one connection rather than thousands. A
  connection is closed after 512 requests anyway, so no client can hold one of
  the poller's slots for the life of the process. A worker lingers on a
  connection it has just answered for ten milliseconds before giving it up, because a client in mid-session has its next request on the wire within
  microseconds and two thread handoffs a request is real money — but only while
  the ready queue is empty and another worker is free.
- Three receive deadlines, not one timeout: 5 s idle between requests on a
  kept-alive connection, 3 s from the first byte of a request to a complete
  header, 5 s from there to a complete body. One number could not be right for
  all three: idle is what a kept-alive connection is *for*, and idle mid-request
  is a stall. An in-flight deadline that passes is answered `408` and closed.
  The poller holds the clock now rather than a worker sitting in `recv`, so a
  stalled connection wakes nobody at all. [PERF-SERVER.md](PERF-SERVER.md) has
  the measurement.
- **One session at a time through a route handler.** A handler is a
  read-modify-write of a whole profile document, and two requests carrying the
  same session id used to run that concurrently and lose one — six concurrent
  purchases each answered `err:0`, three rifles delivered. Dispatch takes a
  lock keyed on the session id across the whole callback. Two profiles do not
  wait on each other, a route with no session takes no lock, and the lock is
  released before the connection waits for its next request. A handler that
  never returns holds its own session and nothing else; a request that cannot
  get the lock within ten seconds is answered `503` rather than pinning a
  worker for good.
- The static tables are served out of a compressed-body cache keyed on the
  response text itself, so a stale hit is impossible by construction, and the
  database is indexed per object so a lookup is a hash lookup rather than a
  scan. The numbers and the reasoning are in [PERF-SERVER.md](PERF-SERVER.md).
- **What is shared between the threads, and what guards it.** Sixteen workers
  and a poller means every table in the server is read from several threads at
  once, and three of them were not guarded at all.

  | | read by | written by | guarded by |
  |---|---|---|---|
  | the database document | every worker, per `db_get` | any thread, per `db_patch` | a reader-writer lock, shared for a read and exclusive for a whole patch |
  | the database index | the same reads | the same reads — the first lookup into an object indexes it | the process lock, always taken *under* the document lock |
  | routes and subscriptions | every worker, per request | mod load and unload, while serving | a reader-writer lock; a walk copies out what it needs and calls nothing while holding it |
  | timers | the serve loop | any thread, per `afterMs` | the process lock |
  | websocket sessions | the poller and every worker | handshake and close | its own lock, never held across a send |

  The document was the loud one. A read took no lock, so a `dbPatch` from a
  route handler or a timer while another request was reading was a
  use-after-free: the reader copies its answer out of the document's buffer,
  and the patch splices that buffer in place and reallocates it when it grows.
  A read holds the lock **shared for the whole call**, copy included, because
  the copy is the half that gets freed underneath it — and shared rather than
  exclusive because the alternative is serialising sixteen workers behind the
  12.5 MB `substr` that answers `/client/items`. Measured against the real
  41 MB database it costs nothing: 227 requests a second before, 230 after.

  Routes were the same shape and quieter. Unloading a mod rebuilt `gRoutes` and
  `gSubs` while workers were walking them, and dispatch carried an *index* into
  that table across the session lock — which is allowed to wait ten seconds —
  so a mod unloaded in that window shifted every index by one and the request
  was answered by whatever slid into its place. Dispatch matches to a copy of
  the route now, under the lock, and the copy is what runs.

  `backend/dbrace.nim` is the gate for the first row: readers and writers on
  one document at once, checking the *answers* rather than checking that the
  process survived. It does seventy thousand concurrent read passes in eight
  seconds without a wrong one; with the lock calls made no-ops it dies inside a
  second. It runs in `aowl test` under the **Backend** heading, at
  `--readers 16 --writers 4 --seconds 8`; the same line drives it by hand from
  `backend\bin\dbrace.exe`.

  The row above it -- routes and subscriptions -- has a gate of its own now, and
  it is about a pointer on a **stack** rather than a pointer in a table. The
  lock protects the table; what it cannot protect is the route a worker has
  already copied out of it and is about to call, in a library the serve loop is
  free to `FreeLibrary` in the meantime. `modhost.modEnter`/`modLeave` hold a
  count around the call and `unloadOne` drains it before it frees anything;
  `backend/modrace.nim` is the proof, and like `dbrace` it asserts on answers:
  workers calling a mod's route while another thread loads and unloads it
  underneath them, with every attempt landing in exactly one of *a whole
  current answer*, *a clean refusal*, *nothing registered* or *a failure*. A
  worker that faults in a freed image is caught by a vectored handler and
  counted rather than allowed to end the run, and an answer carrying the wrong
  incarnation's generation -- what a late call gets when the image was freed and
  mapped again at the same address, without faulting at all -- is counted
  separately, because that is the failure a survival test cannot see. Run it as
  `backend\bin\modrace.exe --cycles 24 --workers 16`; `--unguarded` skips the
  two calls and nothing else and fails every run; `--wedge-ms 8000` holds a
  handler open past the drain's deadline and checks the unload is refused, the
  mod keeps answering, and the same unload then succeeds. It needs
  `racemod.dll` (built from `backend/racemod.c` with
  `gcc -O1 -shared -Iabi -o backend/bin/racemod.dll backend/racemod.c`) beside
  it.
- The mod store keeps a file open once it has touched it — 32 handles, evicted
  least-recently-used. This is not a cache of the contents and could not be:
  the client host and the backend run at the same time against one
  `<root>/store`, so every read still goes to the file. What it removes is the
  *open*, and with it the antivirus rescan that a read-after-write pays on a
  player's machine — 890 microseconds against 3.

## What survives a crash

The store under `<root>/store/<mod-guid>/` holds the only thing this project
has that cannot be rebuilt. Everything else — the database, the mods, the
hosts — is generated, downloaded or compiled. A profile is not, so it is worth
being exact about what the server promises about it.

**A value is never half-written.** A write goes into a temporary file inside
`.hist/` and is then renamed over the key with `MoveFileEx` /
`MOVEFILE_REPLACE_EXISTING`. Replacing a directory entry is atomic on NTFS, so
a reader — this server, the client host, or you with a text editor — sees
either the whole previous value or the whole new one. There is no instant at
which the file is a mixture. That holds against `TerminateProcess`, against the
window being closed, and against the disk filling up mid-write: a write that cannot complete leaves the temporary file
behind and the key untouched. (Power loss is the one case with a caveat — see
`--store-flush` below.)

`tools/storecrash.nim` is the evidence rather than the claim. It kills a
writing process with `TerminateProcess` at jittered points, restarts, and
demands a whole value; it reports how many of those kills landed inside a
commit, and runs the same kills against the in-place write the store used to do
so the coverage figure is checkable. It is in `aowl test` under **The store
under a crash**.

**A write is on disk before the call that made it returns.** Nothing is held in
memory for a later moment, so there is no window in which the server has told a
mod a save succeeded and a crash can still take it away. Killing the server the
instant after a trade, a loadout save or a raid ending loses none of them.

That costs what a commit costs: about 1 ms against 25 µs for the bytes
themselves, because the price is creating the temporary and renaming it, both
of which a real-time virus scanner inspects. It took the write-heavy endpoint
(`items/moving`) from 0.44 ms to about 1.1, and the benchmark mix from ~1500
requests a second to ~800 — six times what a client asks for across a whole
session, and the reason the gate's floor is 500 rather than 800.

Holding writes briefly and committing them together was tried, and it is the
faster answer to the wrong question: it restores the throughput and reopens
exactly the hole this section exists to close. So did keeping a pre-created
file per key to rename — measured, and inside the noise, because the cost is
the rename of a freshly written file rather than the create. Both are written
up above `commitNow` in `host/common/modstore.nim` so the next person does not
have to re-derive them.

**A power cut can lose the last write, unless you ask otherwise.** The commit
does not force its bytes to the medium before renaming: that is
`FlushFileBuffers`, and it is the expensive step by an order of magnitude —
3.9 ms of a 4.3 ms write on the machine `modstore.nim` records — and it does
**not** protect against a crash. The rename does that. It protects against the machine losing
power in the seconds after a write, which can otherwise come back with the
rename applied and the contents not yet written — the one case where this store
can hand back a file that will not parse. `--store-flush` turns it on. A crash
that is not a power cut cannot do that at all: the bytes are in the operating
system's cache before the rename, and the cache survives a process dying.

**There is history.** Every key keeps up to three previous versions under
`<root>/store/<mod-guid>/.hist/<key>.1` … `.3`, written at most once per five
minutes per key so they cost nothing on the request path. They are what a bad
value — a botched migration, a mod writing nonsense — is recovered from, which
atomicity cannot help with because the store commits a bad value perfectly.
To use one, stop the server and copy it over `<root>/store/<mod-guid>/<key>`.

**"There is no profile" and "the profile is unreadable" are different
answers.** A key that was never written returns `ErrNotFound`; a key that is
there and cannot be read returns `ErrGeneric` and is logged as a failure. A mod
that creates a fresh profile when a load fails must check
`load(key).missing` first — creating a new character over a save that a copy
out of `.hist` would have recovered is the one mistake here that costs a player
something they cannot get back.

**One backend per store.** The server claims `<root>/store/.lock-backend` on
startup and refuses to run if another backend already holds it — two servers
writing one profile take turns undoing each other's saves, and the only symptom
is progress that comes and goes. The claim is a file held open with
`FILE_FLAG_DELETE_ON_CLOSE`, so it cannot go stale: however the holder dies,
the kernel releases it. The client host is a different side and takes a
different claim; the two are meant to share a store. `--no-store-lock` is the
override, and running two servers with it is still the data-loss bug it was.

**One backend per port, and it says so.** A second server on a port that is
already taken refuses to start, names the port, and exits non-zero. That reads
like an obvious thing to get right and was not: the listening socket asked for
`SO_REUSEADDR`, which on Windows does not mean "rebind after TIME_WAIT" — it
means *this socket may take a port another process is already listening on*.
The bind succeeded, the second server logged `ok listening on 127.0.0.1:6969`,
and its requests were answered by the first one; its own self test then failed
every route it had just registered with `no route`. Worse than the confusion,
that log line is an interface — `allmods`, `fuzzwire`, `livectl`, `soak`,
`wstest` and `aowlspt-verify` all decide the server is up by finding
`listening` in the log — so a port collision made every one of them wait on a
server that would never answer them and then blame the install. The option is
`SO_EXCLUSIVEADDRUSE` now, which is the one that means what the old comment
thought the other one meant, and the line is written only from the bind's own
result.

**What a player should back up.** `<root>/store/` — the whole directory, which
is every mod's saved state and the `.hist` generations with it. Nothing else
under `<root>` is theirs: `db.json`, `mods/` and the executables all come back
from an install.

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

### And the client that is lying

`aowl test` also runs `tools/fuzzwire.nim`, which drives the same wire with
input no client would send: truncated and garbage zlib, a zip bomb, a
`Content-Length` that disagrees with the body or with itself, urls carrying
quotes and NULs, JSON a hundred thousand levels deep, and every registered
route called with an empty body, `{}`, and a body of the wrong shape. The route
list is **read out of the backend's own log** rather than written down, so an
endpoint added to any mod is covered by the next run.

Three rules make it worth having. Every hostile phase ends by asking an
ordinary question — the config, then the profile list — because a server that
survives by corrupting the profile it was holding has not survived. A refusal
with no reason in it fails, because `400` with an empty body is
indistinguishable from a server that fell over. And the exact bytes go in the
failure line, because a bug report that cannot be replayed goes stale.

What it found, in the backend: `Content-Length: 9000000000000000000` — ninety
bytes on the wire — took the whole process down, because the body buffer was
allocated at whatever the header claimed. There is a ceiling now
(`MaxBodyBytes`, 16 MB) and a declared length over it is a `413` before
anything is allocated. It also found the opposite bug on the way in: any
request body inflating past 65,536 bytes was refused with a `400`, which is
every profile document `match/local/end` posts.

### And the length it is lying about

`backend/framelen.nim` is the second half of that, and it exists because of how
the first half reports. `fuzzwire` sends two absurd lengths among a hundred
other hostile things and asks *at the end of the phase* whether the process is
still there — so a crash is attributed to the last request in the phase rather
than to the one that caused it, and one run of it duly reported the server
dying on `Content-Length: 9000000000000000000` behind a short body, a long
body, a zlib bomb and a zero-length body that had all gone through the same
phase first.

`framelen` is the other shape: one case, one connection, one assertion about
the **answer**, and a liveness probe carrying that case's own name before the
next one starts. It walks the declared length across every boundary arithmetic
has — `int64` and `uint64` max and one past each, `2^31`, `2^32`, the body cap
and one byte over, a hundred nines, three hundred leading zeros in front of an
absurd number — and then the values that are not numbers at all: `-1`, `+5`,
`0x10`, `5abc`, `5, 5`, an empty value, a value that is only spaces. Two
`Content-Length` headers in both orders, agreeing and disagreeing. A body
shorter than its length and a body longer than it. And every one of those again
with a well-formed request pipelined behind it in the same write, where the
assertion is on **how many answers come back**, parsed out of the stream by
each response's own `Content-Length`.

That last one is what it found. A `Content-Length` that was not a number was
read as far as it parsed and the rest thrown away, so `-1`, `+5`, `0x10`,
`5abc` and an empty value were all a length of *zero* — this request has no
body, and the bytes the client sent as its body begin the next request on the
connection. `aowl_scan_length` in `aowlspt_net.h` and `parseHead` here read
them the same way, so the framer and the parser agreed, and there was nothing
to notice: `Content-Length: 5abc`, five bytes of body and one more request
behind it came back as *two* answers, the second of them for a request line
made out of the first one's body. Two parties agreeing that a request ends
before its body is what a request smuggling primitive is. A value that is not
`1*DIGIT` is a `400` now, on both sides, and the framer does not wait for a
body it is about to refuse — fourteen of the tool's checks fail against the
code as it was.

It ends with the shape none of the sequential checks can have: eight threads on
the `408` path — the one answer this server composes on the *poller* thread
rather than a worker, reached in microseconds instead of five seconds by
half-closing the sending side — and four asking ordinary questions beside them,
with the answers all twelve got as the assertion. `connect` failing under the
tool's own load is counted apart from a wrong answer, because a load generator
that reports its own limits as the server's bugs is worse than no tool.

It **is** wired into `aowl test` now — it was not when this was written. The
gate builds it, stages `mods/tarkov` and `emu-full.json` beside it (the tool
decides the server is up by asking `/client/game/config`, so a stage with no
mod in it reports a dead backend about a live one), and runs it on port 6983
as *a lying Content-Length cannot smuggle a second request*. It also builds and
runs by hand the same way `fuzzwire` does, against its own stage and port:

```
nimony c --passC:-I<repo>\abi --passL:-lws2_32 --passL:-lz ^
  -p:<repo>\backend -p:<repo>\installer\src -p:<repo>\aowl\src ^
  -o:<repo>\backend\bin\framelen.exe <repo>\backend\framelen.nim

backend\bin\framelen.exe --root <stage> --backend backend\bin\aowlspt-backend.exe --port 7203
```

102 checks. `--storm` runs only the concurrent phase; `--attach` drives a
server somebody else started, which is how it was used to put the backend under
a debugger while the storm ran.

## What a backend mod does not get

| | |
|---|---|
| `resolve` / `call` | client-side; there is no managed runtime here to reflect into |
| `patch` / `patch_typed` | client-side; there is no compiled game code here to detour |
| `pointerOf` / `pinHandle` | client-side; there is no managed heap here to hold an address in |
| nothing else | events, timers, the store and `notifyPush` all work here |

Every one of those is **present and refusing**, not absent. The backend raises
`AowlHostApi.size` to the revision-5 boundary so that `notifyPush` is reachable,
and one integer cannot say "the fifth and not the third" — so it installs
`ErrUnsupported` implementations of the three above it cannot honour and only
then raises `size`. `livePointersReady()` and `typedPatchesReady()` are
therefore **true on the backend**, and they always meant "there is a function
here that will answer" rather than "this capability works". Branch on `side()`,
or on the status the call returns; do not read a size test as a yes.

`invoke_main` runs the callback where it stands: routes already run on worker
threads, so there is no main thread a mod needs to be moved to.
