# The backend, made fast

The backend replaces SPT's server. "Replaces" is only worth saying if it is
better at the job, so this is the record of what it actually costs to answer a
request, what the costs turned out to be, and what each fix was worth.

Every number here was taken with `tools/benchbackend.nim` on this machine
(Windows 10, msys2 UCRT64 gcc, loopback), against the real emulator
(`mods/tarkov`) over the real wire protocol — sockets, HTTP, zlib framing, the
lot. Nothing is estimated.

## How the numbers were taken

```
benchbackend --backend backend/bin/aowlspt-backend.exe --root <scratch>
             --mod mods/tarkov/bin/tarkov.dll --items 3000 --rounds 20
```

`benchbackend` builds a synthetic database, starts the server as a real child
process, creates a profile, and then drives the mix a client actually produces:

| requests per round | what it is |
|---|---|
| `/client/items` | the largest static table, 4.2 MiB at 3000 templates |
| `/client/globals`, `/client/locale/en`, `/client/handbook/templates` | the other big ones |
| `/client/game/profile/list` | a profile read |
| `/client/game/keepalive` | the small-body floor |
| `/client/game/profile/items/moving` ×25 | the most frequent endpoint in a session: a stash drag, which reads item templates and writes the profile |

Two things about the tool are worth knowing before reading any table.

**The database is generated, not shipped.** A real Tarkov dump is tens of
megabytes and cannot live in a repository, and the 1.8 KB test fixture measures
nothing — every cost in this server is a function of document size, so a
benchmark against a toy database reports that the server is already perfect.
`--items N` sets the scale. 3000 templates gives a 5 MiB document, which is the
same order as a live one; there is a 12000-template (17 MiB) run at the end
because the *shape* of the curve is the real result.

**Latency is reported twice.** `mean`/`p50`/`p95`/`p99`/`max` are round trip:
what a client sees, including its own `inflate` of the answer. `ttfb` is time to
the first byte of the response: the server's share. On a 4.2 MiB body most of
the round trip is the client decompressing, and a round-trip number alone makes
that look like server cost. It is not, and no change to this server can move it.

**Two backends, one mod.** Another agent was rewriting `mods/tarkov` while this
work was happening, and an early comparison was silently ruined by it — the
"after" run was slower on the item-move endpoint because the emulator underneath
had grown, not because the server had. Every A/B below therefore uses one pinned
copy of `tarkov.dll` and two server binaries built from the same tree, one with
the changes reverted.

## Before and after

20 rounds, 3000 templates (5 MiB database, 4.2 MiB `items` body), one connection
per request in both columns so the comparison is like for like.

| endpoint | before, mean | after, mean | before, ttfb | after, ttfb |
|---|---|---|---|---|
| `items` (4251 K) | 72.16 ms | **15.09 ms** | 62.61 ms | **6.75 ms** |
| `locale/en` (677 K) | 27.37 ms | **3.79 ms** | 24.17 ms | **0.79 ms** |
| `handbook` (250 K) | 22.55 ms | **1.40 ms** | 21.45 ms | **0.40 ms** |
| `globals` (196 K) | 11.59 ms | **1.10 ms** | 10.81 ms | **0.37 ms** |
| `profile/list` (5 K) | 1.93 ms | **1.07 ms** | 1.55 ms | **0.73 ms** |
| `items/moving` (1 K) | 25.55 ms | **1.29 ms** | 21.56 ms | **0.95 ms** |
| `keepalive` | 0.46 ms | 0.47 ms | 0.14 ms | 0.15 ms |

620 requests: **15.50 s → 1.11 s**. **39 → 559 requests/second, 14.3×.**

With keep-alive on the client as well — which is how the game talks, and what
the server now supports — the same run is **595 requests/second** and the
percentiles on the frequent endpoint tighten: `items/moving` p99 2.01 ms,
`keepalive` mean 0.15 ms.

## Where the time went, one change at a time

Each row is a measured run. The first three rows were taken before the mod was
pinned, so they are comparable to each other but not to the table above; the
pinned-mod columns pick up from the fourth row.

### 1. Per-byte copies — `items` 71.0 → 57.7 ms

Every body crossed three boundaries a byte at a time.

- `modhost.readBytes` reads a host buffer through `aowl_byte_at`, which is a
  call across a translation unit **per byte**. `runRoute` used it to bring a
  route's answer back from the mod — 4.2 million calls for `/client/items`.
- The backend's own `toBytes`/`fromBytes` were `for i in 0 ..< len: result.add`
  loops, used on the way into `deflate` and back out of `inflate`.
- The uncompressed send path copied the body into a `seq[byte]` purely to have a
  pointer to hand `send`.

All three became one `copyMem` each: `wire.readMem`, `wire.toBytes`,
`wire.fromBytes`, `wire.bytesAt`. `deflateBody` now compresses straight out of
the string via `readRawData`, and the uncompressed path sends from it directly.

The receive side had the same shape of bug in a worse form: `serveConnection`
turned the whole receive buffer into a `string` and ran `find` on it **after
every `recv`**, which is quadratic in the number of segments. It scans bytes now,
and only the bytes that arrived since the last look.

`wire.request` had a fixed 256 KB receive buffer, which silently truncated any
larger response. The symptom was not a short body but "the response body would
not inflate" — a truncated zlib stream is a corrupt one — so a client bug read as
a server fault. It grows now.

### 2. The compressed-body cache — `items` 57.7 → 35.2 ms

Deflating 4.2 MiB of JSON at zlib level 6 costs around 45 ms, and the static
tables are the same bytes on every request.

**The cache key is the response text itself.** That is the whole design, and it
is deliberately not the URL and not a database revision counter. A key derived
from anything else has to be invalidated when the answer changes, and the answer
can change for reasons the HTTP layer cannot see — a `dbPatch` from a timer, a
mod rebuilding a table, a route that varies by session. Keying on the bytes makes
a stale hit impossible by construction: an entry can only be returned for a body
byte-identical to the one it was built from. The price is a `memcmp` per request,
which at 4.2 MiB is well under a millisecond against the 45 it saves.

Bodies under 8 KB skip the cache, because below that the compare costs more than
the deflate. Twelve entries, evicted least-recently-used. The deflate itself
happens outside the lock, so the first request for each of seven large tables —
which the client makes all at once, at boot — does not serialise behind one
worker.

### 3. The database index — the big one

`items` 35.2 → 17.5 ms, `handbook` 20.8 → **1.5 ms**, `items/moving` 26.2 → **1.45 ms**.

`jsondb` addresses the document by dotted path and found each part by walking
the members of an object, *skipping over* every value it passed. Two consequences:

- Anything living after `templates.items` in the document costs a step through
  four megabytes of JSON to reach. That is why `handbook`, whose body is 250 K,
  took as long as `globals`, `locale` and nearly as long as `items`: almost all
  of its time was getting to it, not sending it.
- The emulator reads `templates.items.<id>._props.Width`, `.Height` and
  `.StackMaxSize` on every inventory operation. Each of those was a fresh
  four-megabyte walk. The item-move endpoint, the most frequent one in a session,
  was spending its entire budget there.

The old module comment claimed mods "read a handful of paths at load and patch a
handful more", and that a per-request scan "would be a mistake this module cannot
prevent anyway". Both turned out to be wrong the moment a real game server ran on
it.

Now each object is indexed the first time something addresses it: its immediate
members are enumerated once into a hash table, and every later lookup into that
object is a hash lookup. Building the index costs exactly the scan the first
lookup was going to cost anyway, so no path got slower.

**Invalidation.** The index holds byte offsets into the document, so it is valid
only for the document it was built from. `dbLoad` and every one of the four
places `dbPatchPath` reassigns `gDoc` call `docReplaced()`, which throws the
whole index away. That is deliberately not cleverer than it sounds: a partial
invalidation would have to reason about which offsets a splice moved, and getting
it wrong hands a mod a byte range out of the middle of some other item — a bug
that does not announce itself. Rebuilding is one lazy scan per object actually
touched, and `dbPatch` happens at mod load.

It is locked, unlike the old read path, because the index mutates on *reads* and
reads happen on every worker thread at once.

### 4. Keep-alive — the small endpoints, 3×

The module comment said keep-alive was "a real optimisation and not one worth
having before the endpoints exist". The endpoints exist.

`serveConnection` now loops, keeping whatever arrived past the end of one request
as the start of the next — without that, a pipelined second request in the same
segment is dropped and the client waits for an answer that was thrown away.
`Connection: close` is honoured, HTTP/1.0 defaults to close, and a connection is
closed after 512 requests regardless.

Client side, `wire.Conn`/`requestOn` hold one socket open. The read frame changes
with it: there is no end-of-stream to read to, so the keep-alive path reads
exactly the `Content-Length` the response declares. `wire.request` is untouched
and still says `Connection: close`, so `aowlprobe` and `--selftest` work against
any server, including one that does not do keep-alive.

Measured, same run with and without:

| endpoint | close per request | one connection |
|---|---|---|
| `keepalive` | 0.466 ms | **0.151 ms** |
| `profile/list` | 1.070 ms | **0.756 ms** |
| `handbook` | 1.398 ms | **1.056 ms** |
| `items/moving` p99 | 1.845 ms | **2.010 ms** (mean 1.285 → 1.259) |
| whole run | 559 req/s | **595 req/s** |

Holding a connection means holding a worker, so two things changed with it: the
pool went from 4 to 8 (ceiling 16 in `aowlspt_net.h`), and the receive deadline
drops from 15 s to 5 s once a connection is idle between requests. Neither is a
measured speedup — `benchbackend` drives one connection and cannot show either
way — and both are stated as robustness, not performance.

## Scaling: the shape is the result

The same mix against a 17 MiB database (12000 templates), 6 rounds:

| endpoint | before | after | before ttfb | after ttfb |
|---|---|---|---|---|
| `items` (17028 K) | 310.9 ms | **78.6 ms** | 264.2 ms | **35.6 ms** |
| `locale/en` (2720 K) | 111.9 ms | **18.8 ms** | 97.9 ms | **5.4 ms** |
| `handbook` (1006 K) | 93.9 ms | **4.4 ms** | 90.5 ms | **1.2 ms** |
| `items/moving` (1 K) | 85.6 ms | **1.32 ms** | 81.7 ms | **0.99 ms** |

**11 → 219 requests/second, 19×.**

The row that matters is the last one. Between the 5 MiB database and the 17 MiB
one, the item-move endpoint went from 21.6 ms to 81.7 ms of server time before,
and from 0.95 ms to 0.99 ms after. The endpoint a player hits thousands of times
per session no longer scales with the size of the database at all. That is the
index doing its job, and it is a better result than any of the constant factors.

## What is left, and what it is

`/client/items` at 3000 templates: 14.0 ms round trip, 6.1 ms to first byte. The
8 ms difference is `benchbackend` inflating 4.2 MiB, at roughly the rate zlib
decompresses. Nothing the server does can change it.

Of the 6.1 ms the server does spend, most is memory traffic: the answer is copied
about seven times between the database and the socket — `dbGetPath` cuts the
subtree out of the document, `aowl_out_copy` allocates a host buffer for it, the
mod's `takeBuffer` copies it into a string, `envelope()` concatenates it into
another, `allocBuffer` copies that back into a host buffer, `readMem` copies it
into the server's string, and the cache compares it. Four of those seven live in
`aowl/src` and the ABI, which this work did not own — see the API gaps below.

The other honest limit is that a single-player game server is not throughput
bound. 595 requests/second against a client that issues perhaps a few dozen per
second means the interesting number is now the tail, and the tail is clean:
`items/moving` p99 is 2.0 ms.

## Tried, kept out

- **A lower zlib level.** Level 1 would cut the first deflate of each table, but
  the cache means each table is deflated once per process, so it buys a few tens
  of milliseconds at boot in exchange for a permanently larger body on the wire
  for every dynamic response. Not worth it.
- **Caching `dbGetPath` results by path string.** Subsumed by the object index,
  which is strictly better: it also serves paths that have never been asked for
  before, as long as their parent object has.
- **Growing the accept pool for throughput.** The bench drives one connection;
  there is no number to show, so the pool change is justified as robustness under
  keep-alive and nothing else.

## Correctness

`--selftest` passes, 7 of 7.

`emutest` is the harder gate, and it was moving underneath this work: another
agent was adding emulator features while it ran. The check that means anything
is therefore not the absolute pass count but the **difference between this
backend and the unmodified one**. Both were run against the same staged
emulator, the same fixture and the same store, back to back:

```
optimised backend   3 of 135 failed
baseline backend    3 of 135 failed   (the same three)
```

The three are the emulator's own in-flight flea-market work — an offer counted
twice, an expired offer's mail carrying no items. Nothing in this work is
implicated, and running the identical suite against the pre-optimisation binary
is the check that says so. An earlier run in the same session showed 29 of 119
failing on both, for the same reason.

The stale-cache bug this design was built against — a compressed body served
after a `dbPatch` changed the answer — cannot occur: the cache key is the
response text, so an entry is only ever returned for a body identical to the one
it was built from. The database index, which *can* go stale because it is byte
offsets, is thrown away at every one of the five places the document is
reassigned.

## Reproducing

```
# build the bench
nimony c --passC:-I<repo>/abi --passL:-lws2_32 --passL:-lz \
  -p:<repo>/backend -p:<repo>/installer/src -p:<repo>/aowl/src \
  -o:<repo>/installer/build/benchbackend.exe tools/benchbackend.nim

# run it
installer/build/benchbackend.exe \
  --backend backend/bin/aowlspt-backend.exe \
  --root <scratch> --mod mods/tarkov/bin/tarkov.dll \
  --config mods/tarkov/config.json \
  --items 3000 --rounds 20 --keepalive --label "whatever you changed"
```

`--label` exists because the only way to trust a before-and-after is to have
both printed with the thing that distinguishes them. Pin the mod DLL if anything
else in the tree is moving.
