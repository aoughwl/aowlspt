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
only for the document it was built from. In this pass `dbLoad` and every one of
the four places `dbPatchPath` reassigned `gDoc` called `docReplaced()`, which
threw the whole index away — deliberately not cleverer than it sounds, because
a partial invalidation has to reason about which offsets a splice moved, and
getting it wrong hands a mod a byte range out of the middle of some other item.

That held while `dbPatch` only happened at mod load and mods only patched a
handful of things. It stopped holding: throwing the index away *is* what made a
write cost the whole document, and the cost surfaced as a 54 second boot. What
replaced it — anchor coordinates, and a short list of edited regions to
translate through — is the last section of this file.

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
# build the bench -- `aowl build` does this now; it did not when the numbers
# above were first taken, which is why they were hard to reproduce
aowl build

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

Add `--perf` for the server's own per-phase breakdown — where inside the answer
the time went, rather than how long the answer took. See the next section.

# The second pass: measuring first

Everything above is one body of work. What follows is the next one, and it
started by building the instrument the first pass did not have.

## The instrument

`benchbackend` says what a request costs. It cannot say *what* the cost was —
whether an item move spent its milliseconds in zlib, in the merge-patch
database, in the socket, or somewhere nobody had thought to look. The first
pass answered that by reasoning about the code, which worked, and would not
have worked twice.

So the backend now carries `--perf`: per-phase accumulators in
`backend/perfphase.nim`, off by default, one predictable branch per call site
when off. It times the five phases of answering a request — inflate, route
match, the route itself, deflate, send — and, nested inside `route`, the four
host callbacks a mod spends its time in: `db_get`, `db_patch`, `store_get`,
`store_set`. `route` minus its children is the mod's own work, which is the
number the whole exercise is after. It also prints the compressed-body cache's
hit rate, which the design above rests on and which nothing was reporting.

The report is written to `<root>/perf.txt` once a second as well as at exit,
because a load generator kills the server rather than asking it to stop, and a
report printed at exit is a report nobody ever sees. `benchbackend --perf`
passes the flag through and prints the file.

`aowl build` now builds `benchbackend` (`buildBench`), which it did not: the
numbers in this file were taken with a tool that had to be compiled by hand
from a command line kept in somebody's scrollback.

## The profile, before

3000 templates, 20 rounds, keep-alive, 716 requests including warmup. Totals in
milliseconds across the whole run.

| phase | total ms | calls | mean us |
|---|---|---|---|
| `route` | 949.7 | 716 | 1326 |
| — `store_get` | **362.0** | 627 | **577** |
| — `store_set` | **275.0** | 578 | **475** |
| — `db_get` | 56.0 | 1248 | 44 |
| — `store_list` | 5.5 | 27 | 203 |
| `deflate` | 76.5 | 716 | 106 |
| `inflate` | 30.0 | 716 | 41 |
| `send` | 26.2 | 716 | 36 |
| `match` | 1.0 | 716 | 1 |

Two thirds of all server time was the profile store — 637 ms of the 950 ms
spent inside routes, against 76 ms for all compression and 56 ms for every
database lookup in the run. The endpoint that mattered, `items/moving`, was
spending essentially its whole budget reading a 3 KB file and writing it back.

Nothing in the first pass was wrong. It was simply looking at the parts of the
server that are made of code, and the cost was in the part made of syscalls.

## Why a 3 KB file cost 577 microseconds

It is not the disk, and it is not the directory lookup. Measured directly, on
this machine, on a 3 KB file:

| | |
|---|---|
| open + read + close, file unchanged since last time | **35 us** |
| open + write + close | **176 us** |
| open + read + close, immediately after writing it | **890 us** |

Real-time antivirus rescans a file when it is opened *and has been modified
since the last open*. The profile store does exactly that, once per inventory
move: read the profile, mutate it, write it back, and read it again on the next
move. Every read in the benchmark was a read-after-write, and paid the scan.

That is not a Windows detail to be worked around cleverly. It is what the file
API costs on a player's machine, and the answer is to stop calling it.

## What changed, and what each was worth

Each row is a measured run against the same pinned `tarkov.dll`, keep-alive,
3000 templates, 20 rounds.

### 1. The store stops paying for the installer's caution — 600 → 691 req/s

`storeWrite` went through `winfs.writeTextFile`, whose contract is the
installer's: ensure the parent directory, check whether the destination exists,
**delete it**, then create it. The delete is there because an installer's
destination may be a hard link into a game install that must not be written
through. A file the host made, in a directory the host made, is not that.

Seven filesystem round trips became one. `store_set` 475 → **206 us**.
`storeRead`'s `exists` probe went too: a missing file and an unreadable one
both fail the open, so the probe only ever bought a better error message, which
is now recovered on the failure path where a syscall costs nothing.

### 2. Reads through `ReadFile` rather than the buffered `File` — 691 → 696 req/s

`store_get` 577 → **309 us**. Real, and it turned out to be the small half of
that number.

### 3. `dbGetPath` stops copying the answer twice — `db_get` 44 → 31 us

`strip(gDoc.substr(vs, ve - 1))` reads as one operation and is two allocations
of the whole value: `substr` cuts it out, `strip` copies the result again to
shave whitespace off the ends. On `templates.items` that is four megabytes
copied for nothing — `locate` has already left the start index past the leading
whitespace, so `strip` has nothing to do. The indices are trimmed instead and
the value is cut once.

### 4. The inflate buffer is sized to the body — `inflate` 41 → 6 us

`inflateBody` allocated `max(rawLen * 64, 65536)` bytes and zeroed them. Every
request the client makes carries a body of a few hundred bytes, so every
request allocated and zeroed 64 KB in order to inflate 200 bytes into it, and
the allocation cost seven times the decompression. It is 16x with a 4 KB floor
now, retried at 8x on failure so that a body which does not fit is slower
rather than refused. 30.0 ms → **4.5 ms** across the run.

### 5. The store keeps its files open — 715 → 930 req/s

The one that mattered. `modstore` holds a handle per file it has touched,
bounded at 32 and evicted least-recently-used, opened `GENERIC_READ |
GENERIC_WRITE` and shared every way — read, write and delete — so the other
host may open, rewrite or even delete the file while it is held. A read seeks
to the start and reads the file; a write seeks to the start, writes, and
truncates, which is what `CREATE_ALWAYS` did without the create.

| | before | after |
|---|---|---|
| `store_get` | 529 us | **12 us** |
| `store_set` | 205 us | **43 us** |
| `items/moving` mean | 0.938 ms | **0.418 ms** |

**This is not a cache of the contents, and the difference is the whole reason
it is safe.** Every read still goes to the file, through the operating system's
page cache, so a write by the other host is seen exactly as it is seen today.
The client host and the backend run at the same time against one
`<root>/store` — that is what the module is for — and neither can be told when
the other has written. A cache of the values would be faster still and would be
wrong. Removing the *open* removes the antivirus rescan without touching the
coherence.

### 6. One `send` for a small answer — 930 → ~1030 req/s

The header and the body went out as two `send` calls, which is two system calls
and two segments, and the second is at the mercy of Nagle: this socket has no
`TCP_NODELAY`. On loopback that rarely bites, and it is not a risk worth
carrying to avoid copying a kilobyte — which is what almost every response
here is. Bodies over 64 KB still go out on their own, straight from the
compressed buffer or the response string, because above that the copy would be
the larger cost of the two.

### 7. `byref` on the response path — no measurable effect

`zFind`, `cachedDeflate` and `sendResponse` took the response body by value.
`inflateBody` carries a comment explaining why that matters for a `seq`, so the
same bug in the same file for a `string` looked like the obvious next find. It
measured as nothing — nimony was not copying — and the annotations are kept
because they are correct and cheap, not because they bought anything.

## Before and after

Same pinned mod, same machine, both binaries built from the same tree, one with
the changes reverted. Interleaved, because the machine has other work on it and
two runs half an hour apart are not a comparison. Median of five pairs:
**536 → 1015 requests/second, 1.9x.** The table below is one such pair.

| endpoint | before, mean | after, mean | before, ttfb | after, ttfb |
|---|---|---|---|---|
| `items` (4251 K) | 14.49 ms | 13.10 ms | 6.53 ms | **5.24 ms** |
| `locale/en` (677 K) | 3.54 ms | 3.42 ms | 0.81 ms | **0.70 ms** |
| `handbook` (250 K) | 1.07 ms | 1.02 ms | 0.34 ms | 0.32 ms |
| `globals` (196 K) | 0.76 ms | 0.72 ms | 0.32 ms | 0.29 ms |
| `profile/list` (5 K) | 1.51 ms | **0.54 ms** | 1.40 ms | **0.45 ms** |
| `items/moving` (1 K) | 1.46 ms | **0.41 ms** | 1.35 ms | **0.31 ms** |
| `keepalive` | 0.15 ms | 0.15 ms | 0.07 ms | 0.08 ms |

620 requests: 1165 ms → **589 ms**. `items/moving` p99 2.10 ms → **0.53 ms**.

Against the 17 MiB database (12000 templates, 6 rounds): **245 → 311
requests/second**, and `items/moving` server time 1.293 ms → **0.333 ms** —
which is the same 0.311 ms it costs against the 5 MiB one. The endpoint a
player hits thousands of times per session now scales with neither the size of
the database nor the size of the profile document.

## The profile, after

| phase | before | after |
|---|---|---|
| `route` | 949.7 ms | **303.1 ms** |
| — `store_get` | 362.0 ms | **7.1 ms** |
| — `store_set` | 275.0 ms | **23.0 ms** |
| — `db_get` | 56.0 ms | **38.5 ms** |
| `deflate` | 76.5 ms | 73.7 ms |
| `inflate` | 30.0 ms | **4.3 ms** |
| `send` | 26.2 ms | **19.8 ms** |

The shape has changed completely. The store has gone from two thirds of the
server to under ten percent of it, and what is left inside `route` — 303 ms
less its 73 ms of host calls — is the emulator's own work in `mods/tarkov`,
which this pass did not own.

`deflate` is now the largest thing the server itself does, and 88 of its calls
are cache *hits*: `zcache 88 hits, 4 misses, 624 bodies under the size it
caches`, which is exactly right — four large tables, deflated once each, served
88 times. A hit costs about 0.9 ms on `/client/items` and almost all of that is
the `memcmp` of a 4.2 MB body against the cache key. That is the design, not a
defect in it: the key is the response text precisely so that a stale hit is
impossible, and a hash would have to read the same four megabytes.

## The gate

`aowl test` now runs `benchbackend --floor 800` against a 1000-template
database and fails the build under it. It prints the number either way.

The floor is set well under what this machine does (≈1550 req/s on that
configuration) because it is a check against a regression of *kind* — a
per-byte copy reintroduced, a cache that has stopped hitting, a store that has
gone back to opening a file per read — each of which halves the number or
worse. The backend before this pass manages 710 on the same configuration, so
the floor sits above it: the specific regressions this work guards against
would trip it.

## Slow clients, and what the pool is really limiting

A finding from the fuzzing pass landed in the middle of this one, and it is a
serving-architecture problem rather than a throughput problem, so it belongs
here: **twelve dead connections locked every other client out.**

A socket that declares a `Content-Length` and then sends nothing parks a worker
inside `recv` for the whole in-flight receive timeout. The accept pool is a
fixed set of threads each blocking on `accept`, so the pool size *is* the
concurrency limit, and a worker blocked in `recv` has taken one of its slots.
`fuzzwire` opens twelve such sockets and times an ordinary request behind them:

```
twelve stalled connections shut every other client out for 10007 ms
```

Ten seconds is when the *client* gave up; the server was going to hold those
workers for fifteen. A client that keeps reconnecting keeps them held.

### One timeout could not be right

The socket had a single `SO_RCVTIMEO`: fifteen seconds while a request was in
flight, dropped to five once a keep-alive connection went idle. That is one
number doing three jobs, and it is wrong for at least one of them however it is
set. Idle between requests is what a kept-alive connection is *for* and wants a
generous wait; idle in the middle of a request is a stall and wants a short
one; and a wait long enough for a genuinely slow sender is by definition long
enough to be worth attacking.

So `SO_RCVTIMEO` is now a 500 ms *slice* rather than a deadline, and
`recvBounded` distinguishes `WSAETIMEDOUT` — nothing yet — from a zero-length
read, which is an orderly close. A slice that expires with time left simply
goes round again, so a client dribbling a byte a second is not mistaken for one
that has stopped. What ends a wait is a wall-clock deadline, and there are
three of them:

| | |
|---|---|
| idle between requests, keep-alive | 5 s |
| first byte of a request → complete header | 3 s |
| complete header → complete body | 5 s |

Three seconds to finish a set of headers is not tight: this server listens on
loopback and nowhere else. A client that has begun a request and cannot finish
it in that is not slow, it is stuck. Either in-flight deadline now answers
`408` and closes rather than waiting, and a body that stops arriving is
answered rather than handed to a route as a short one — asking a mod to tell a
truncated document from a malformed one is asking for something it cannot do.

### And the pool is sixteen

The deadlines bound how long a stalled connection holds a worker. How many
stalled connections it takes to be *felt* is the pool size, which was eight —
so twelve of them starved it outright. It is sixteen now, the ceiling
`aowlspt_net.h` already allowed, so the twelve `fuzzwire` throws leave four
workers free.

```
before   twelve stalled connections shut every other client out for 10007 ms
after    ok    stalled connections do not delay an ordinary request
```

**This bounds the damage; it does not remove the shape.** A client with more
sockets than the pool can still fill it, five seconds at a time. Removing that
means a non-blocking, poll-driven accept and read path — one worker serving
many connections, so that a connection making no progress costs a file
descriptor rather than a thread. That is a rewrite of the C pool in
`abi/aowlspt_net.h`, a header both hosts include, and it is the right next
change rather than one to make in passing. What is here turns a denial of
service into a five-second annoyance and puts a measured number on the
remainder.

Throughput is unchanged by it: 1013 and 1012 requests/second on the two
interleaved runs taken after, against 1015 median before.

## The gate went red the same afternoon

Within half an hour of the floor being installed it failed, and this is the
record of that rather than a reason to move the floor.

The store write became an atomic commit while this pass was finishing: value
into a temporary file, `FlushFileBuffers`, `MoveFileEx` over the key. The
hazard it is aimed at is real — a process killed part-way through an in-place
overwrite leaves a profile that is a mixture of two values, which is the one
loss nothing afterwards repairs. The cost of it, measured the same way as
everything else in this file:

| write of a 3 KB value | |
|---|---|
| in place, through a held handle | **19.6 us** |
| temp + rename | 473.8 us |
| temp + `FlushFileBuffers` + rename | **4335.9 us** |

and end to end, through the server, `store_set` measured by `--perf`:

```
store_set     24419.448 ms      124 calls      196931 us
```

197 milliseconds per profile write, against 43 microseconds an hour earlier.
The gate configuration went from ~1430 requests/second to **6**:

```
Gate
----
error 15 requests/second is under the floor of 800
```

Two things are worth separating, because they are not the same decision.

**The flush is not what makes the write atomic — the rename is.** A process
killed at any point still leaves either the old file or the new one, because
the rename is a single filesystem operation and the page cache survives a dead
process. `FlushFileBuffers` adds protection against the machine losing power,
which is a different and much rarer failure, and it is 3.9 ms of the 4.3.
Dropping it keeps the guarantee the code's own comment claims and was measured
end to end at 11 → 15 requests/second — real, and not the main cost.

**The main cost is the commit itself**, and it is worth more than the 24x the
microbenchmark suggests once a live directory and real-time antivirus are
involved: every write creates a new file at the key's path, which is a new file
for the scanner to look at. That is the same effect documented above for
read-after-write, arriving from the other direction.

None of that says the atomic write is wrong. It says the profile is written on
every inventory drag, and a commit protocol priced for a save point is being
paid thousands of times a raid. Somewhere between the two — committing on a
schedule and at the points that matter, writing in place between them — is a
design decision rather than an optimisation, which is why this section records
the numbers and does not make it.

The floor stays at 800. A gate moved to accommodate the regression it caught is
not a gate.

## Tried, kept out

- **Caching store values in memory.** It is the obvious next step and it is
  wrong. The client host and the backend run at the same time against one
  `<root>/store`, and a value one of them cached is a value the other can
  invalidate with no way for either to find out. Validating a cached copy with
  a timestamp does not close the hole — NTFS write times are updated with far
  coarser granularity than two writes can be apart. Holding the file open gets
  most of the same speed and keeps the coherence, so that is what is there.
- **Reusing one `z_stream` per thread instead of `compress2`.** `compress2` is
  `deflateInit2` + `deflate` + `deflateEnd` per call, and `deflateInit2` at
  level 6 allocates about a quarter of a megabyte every time. It was
  implemented, verified byte-identical against `compress2` over 500 inputs, and
  measured: **0.5%**. The estimate that motivated it — 95 us per small response
  — was wrong; the `deflate` phase is dominated by the cache hits, not by the
  small bodies. It was reverted, and `abi/aowlspt_net.h` is unchanged, because
  a shared header that both hosts include is not worth editing for half a
  percent.
- **A lower zlib level.** Still no: it would change the bytes on the wire for
  every dynamic response, and the tables that would benefit are cached anyway.
- **`TCP_NODELAY`.** It would be an `abi/` edit; sending the header and a small
  body in one call gets the same result without one.

## Correctness

`--selftest`: 7 of 7.

`emutest` is the gate that means something, and it was moving underneath this
work again — another agent was adding emulator features while it ran. So the
check is not the pass count but the *difference*, both binaries against the
same pinned `tarkov.dll`, the same fixture and a fresh store each:

```
this backend       21 of 149 failed
baseline backend   21 of 149 failed
```

and the failing sets are byte-for-byte identical, compared line by line. The
21 are the emulator's own in-flight work; nothing in this pass is implicated.

The store change is the one with a correctness story worth stating plainly.
Held handles do not change what is in the file or when: `WriteFile` has reached
the kernel before the call returns, so a killed process loses nothing that a
`CloseHandle` would have saved — only a machine crash does, which was true of
the buffered write before it. `emutest` exercises exactly this, restarting the
backend mid-suite and checking that a hideout craft, its clock and a redeemed
reward survived; it does, on both binaries.

# The third pass: the pool stops being the connection limit

The pass above ends by naming its own remainder — *a client with more sockets
than the pool can still fill it, five seconds at a time* — and says the fix is
a poll-driven accept and read path in `abi/aowlspt_net.h`. This is that.

## What was actually wrong

Nothing about the deadlines. They were right and they are unchanged. What was
wrong is one sentence: **a worker thread was taken at `accept` and given back
at `close`.** Keep-alive means a connection lives for a session, so the pool
size was the number of *connections* the server could have, and every number
anyone might pick for it is a number an attacker can exceed with a `for` loop.
Eight was starved by twelve; sixteen would be starved by twenty.

## The shape now

One **poller** thread owns the listening socket and every connection that is
not currently being answered. It sits in `WSAPoll`, accepts, and reads whatever
has arrived into that connection's buffer. It never runs a route.

A connection reaches a **request worker** only when a complete request is
buffered — headers and the whole declared body. The worker answers it and hands
the connection back.

So a connection that stalls, dribbles, or opens and says nothing never touches
a worker. The sixteen threads are now the concurrency limit on *answering*,
which is the only thing a thread was ever needed for, and the limit on
connections is `AOWL_NET_MAX_CONNS` (1024) and `AOWL_NET_MAX_BUFFERED`
(64 MiB) — sockets and memory, not threads.

**WSAPoll rather than IOCP**, and the reasoning is written at the head of
`abi/aowlspt_net.h` along with what it costs: an O(connections) scan per
wakeup, and one thread doing all the reads. This is a loopback server for one
game; IOCP's advantage begins where this server ends, and it would turn the
"have I got a whole request yet" loop into a set of completions with a buffer
lifetime attached to each — the bug class this file must not have.

## The measurement

`fuzzwire` grew a check the old server cannot pass. It opens 256 stalled
connections in three shapes — a socket that says nothing, one that dribbles
half a request line, one that declares a body and never sends it — and times an
ordinary request behind them.

```
baseline backend   error an ordinary request is answered behind 243 stalled
                         connections: no answer after 10004 ms
this backend       ok    an ordinary request is answered behind 256 stalled
                         connections    (it took 0 ms)
```

The baseline only reached 243 because it could not accept the rest. Ten seconds
is again where the *client* gave up.

By hand, at 900 stalled connections:

| | |
|---|---|
| backend resident set, idle | 5.4 MiB |
| backend resident set, 900 stalled connections | 11.8 MiB |
| an ordinary request, behind those 900 | 1.6 ms |

About 7 KiB a connection, and only for the ones that have actually sent
something: the buffer is allocated on the first byte received and grows with
what arrives, never with what a `Content-Length` claims. A socket that connects
and says nothing owns no buffer at all, and is dropped after the 3 s header
deadline. **The bound is 1024 connections and 64 MiB of buffered request.**

## The three things that made it slower, and what each cost

This is the interesting half. The first working version was **15% slower**, and
none of the reasons were where they were looked for.

### 1. The session lock — 15%, and it is never contended

The per-session lock (below) was first an `SRWLOCK` plus a
`CONDITION_VARIABLE` per slot, with a `WakeConditionVariable` on every release
so a timed wait could work. Completely uncontended — one connection, one
session, one request at a time — it cost around **seventy microseconds a
request**, which is 15% of the whole server. Disabling it took the new binary
from 1290 back to 1548 req/s against a baseline of 1515.

It is now `TryAcquireSRWLockExclusive` on the way in and
`ReleaseSRWLockExclusive` on the way out: two interlocked operations in the
case that always happens, and a yield loop in the case that almost never does.
A lock taken on every request and contended on none has to be free when it is
uncontended before it is anything else.

### 2. Non-blocking sends — the 1.4 MiB response, +35%

Making the accepted socket non-blocking for the poller made it non-blocking for
the response too, so `aowl_net_send` began partial-sending the item table and
waiting for `POLLWRNORM` between the pieces. `items` went 4.28 to 5.79 ms.

The socket is now put *back* into blocking mode by the worker that picks the
connection up, with `SO_SNDTIMEO` supplying the bound that non-blocking was
giving, and returned to non-blocking only when the connection goes back to the
poller.

### 3. Handing the connection back too eagerly — a flat 70 us a request

The worker's grace window — the short wait for the next request before giving
the connection up — first returned to the poller on *any* short read. A request
with a body arrives as a header segment and a body segment, so nearly every
request handed the connection back and picked it up again, and two thread
wakeups landed on the critical path of almost every answer. It read as a flat
cost on every endpoint, from the item table down to the empty-bodied keepalive.

It now keeps reading while bytes keep coming, capped at `AOWL_HOT_READS`, and
lingers for `AOWL_HOT_GRACE_MS` only when the ready queue is empty *and* at
least one other worker is not lingering either. Without that second condition
sixteen hot connections could put every worker in a grace window at once, which
is the failure this whole change removes, rebuilt out of smaller parts.

## Throughput

Interleaved A/B on one tree, with the baseline binary rebuilt from the
*current* sources before each round. Three other agents were editing
`host/common/modstore.nim`, `backend/jsondb.nim` and `mods/tarkov` while this
ran, and a baseline frozen an hour earlier measures their work as well as this
one — an early set of numbers had to be thrown away for exactly that reason:
both binaries dropped from ~1500 to ~800 req/s between two runs and the cause
was somebody else's store change.

The same interference makes the median unusable — both sides show runs at a
third of their rate. The honest statistic on a contended machine is the *best*
run, which is the one least interfered with:

```
18 interleaved pairs, 20 rounds each, on a machine running three other builds
baseline   best 872 req/s
this pass  best 851 req/s     -2.4%
```

An earlier set taken on a quieter machine, same method:

```
9 interleaved pairs
baseline   median 1515 req/s   best 1566
this pass  median 1483 req/s   best 1548     -2%
```

Per endpoint, at parity or better on the median request and slightly worse on
the mean — the mean carries the handful of requests that took the cold path
through the poller:

```
                base p50   this p50      base mean   this mean
items             4.257      4.203          4.225       4.415
items/moving      0.417      0.411          0.421       0.446
keepalive         0.151      0.149          0.151       0.141
```

So: **about 2% down, at the edge of what this machine can resolve**, in
exchange for the connection limit going from sixteen to 1024 and the cost of a
stalled connection going from a thread to 7 KiB. The `--floor 800` gate still
passes.

## Serialising a session

A second finding landed in this pass, from the same fuzzing work: **concurrent
requests against one profile lost updates.** Six concurrent `buy_from_trader`
were each answered `err:0`; three rifles arrived and 75,000 was paid. The
arithmetic was self-consistent and nothing duplicated — three purchases were
simply discarded while the client was told they had succeeded.

Profile handling is a read-modify-write of a whole document and the mod API has
no mutex, so the emulator could only narrow the window: every save stamps a
per-profile counter and the item-event endpoint refuses when it moved.
`mods/tarkov/emu/profile.nim` says in as many words that this narrows and does
not close, and that the fix belongs in the host.

It is in the dispatch path now, because that is the only place that knows a
request is about to begin and has somewhere to put a lock. `aowl_session_lock`
in `abi/aowlspt_net.h`:

- **The whole callback**, not the store call. The read and the write are at
  either end of the handler.
- **Keyed on the session**, matched exactly on the 24-character id in a table
  that is only ever added to. Two profiles do not wait on each other, and a
  route with no session — the status routes, the mod manager — takes no lock at
  all.
- **Per session, not per connection.** It is released before the response goes
  out and long before the connection waits for its next request, so keep-alive
  holds nothing. Holding it across a keep-alive wait would rebuild the
  thread-per-connection stall this pass exists to remove.
- **A handler that never returns** holds its session's lock for as long as it
  runs, and nothing can be done about that: releasing a lock under a handler
  that is still writing is the lost update this exists to prevent. What is
  bounded is the blast radius. Other sessions carry on, and a request that
  cannot get the lock in ten seconds is answered `503` rather than pinning a
  worker for the life of the process.

`benchbackend` drives one connection and so measures only the cost — which is
where the 15% above came from and is now two interlocked operations.
`fuzzwire`'s concurrency checks are where the benefit is, and they pass.

## Correctness

Every gate was run against the tree *before* this work started, because several
of them are red for reasons belonging to other agents' in-flight work and this
pass must neither be blamed for those nor hide behind them.

```
                 before            after
--selftest       8 ok, 0 failed    8 ok, 0 failed
fuzzwire         148 ok, 0 failed  151 ok, 0 failed   (three new checks)
livectl          43 ok, 0 failed   43 ok, 0 failed
emutest          237 ok, 8 failed  244 ok, 1 failed
```

`emutest`'s eight were all in "Across a restart" — a hideout craft, a trader's
turnover and a redeemed reward that did not survive one. Seven of them stopped
failing with this change and nothing here was aimed at them; the honest reading
is that they were the lost-update race, which is what the session lock closes.
The one that remains, a saved weapon build, is the emulator's own work.

Later the same day the emulator stopped booting at all on `mods/tarkov`'s
in-flight state. That is recorded rather than worked around, and it was checked
the way the pass above checks this kind of thing — both binaries, the same
pinned `tarkov.dll`, the same fixture, a fresh store each — and they fail
identically.

## What is deliberately unchanged

Byte for byte on the wire, and each of these was checked rather than assumed:

- Every status line, header and response body is still composed in nimony.
  `aowlspt_net.h` writes nothing: the two `408`s a stalled request gets are a
  call back into `aowlspt_nim_timeout` rather than a `send` from C.
- The 512-request keep-alive cap still applies *after* the response has gone
  out, so request 512 is still answered `Connection: keep-alive` and the socket
  still closes under it.
- `Accept-Encoding: identity` handling, the zlib framing both ways, the
  unframed-request tolerance and the 24-hex session check are untouched —
  `parseHead` and `sendResponse` were not edited at all.
- The three deadlines keep their values and their meanings; only the thing
  holding the clock changed.
- A peer that closes between requests or mid-headers still gets nothing back; a
  peer that closes mid-body still gets the `408` the old body loop sent.
- `aowl_net_serve`, `aowl_net_running` and `aowl_net_stop` keep their
  signatures and their meanings. The one shape that had to change is the
  callback: `aowlspt_nim_serve(sock)`, which owned a connection, is now
  `aowlspt_nim_handle(sock, buf, len, headEnd, sep)`, which answers one
  request. `tools/aowlprobe.nim`, the only other file in the repo that defines
  the symbol, was updated in the same change.

# A write costs the patch, not the document

Later pass, same instrument, same machine. Everything above this line is about
what a *read* costs. This is about what a write costs, which nothing had ever
measured, and the answer was: the document.

## The finding

`dbPatchPath` ended in

```nim
gDoc = gDoc.substr(0, vs - 1) & merged & gDoc.substr(ve)
docReplaced()
```

Two whole copies of the document, concatenated into a third, and then the index
thrown away so that the next read rebuilt it by scanning. Timed directly against
the 41 MB imported database, with a 200-byte patch:

| | 41 MB imported | 51 KB fixture |
|---|---|---|
| `db_patch` of an existing value | **171 ms** | 0.201 ms |
| `db_patch` creating a path | **109 ms** | 0.193 ms |

It is 171 ms whatever the patch says. The cost was `writes x sizeof(document)`,
and every test in the repo ran against a fixture of a few dozen entries, which is
a benchmark that reports the problem does not exist.

Four mods had grown their own write buffering to get around it -- 363 changes
folded into 2 writes, 420 patches into 10 -- which is a thing every future mod
would otherwise also have to know.

## What replaced it

**The splice happens in place.** `beginStore` returns the string's own buffer
and, for a long uniquely-owned string with room, allocates and copies nothing --
so a patch is one `moveMem` of the bytes after the edit plus a `copyMem` of the
patch itself.

**The index survives the splice.** Every offset after an edit moves by a *known*
delta, so the index is no longer held in the document's live coordinates: it is
held in **anchor coordinates**, the coordinates the document had when the index
was last rebuilt, plus a short sorted list of the regions that have been
replaced since. A lookup binary searches that list once per path segment --
nothing beside the hash lookup it accompanies -- and a write appends one entry.

Every ambiguity fails closed, to a **rebase**: the index is translated into the
current document's coordinates and the list emptied. Only the entries that
cannot be translated are dropped, and an object that loses one member loses all
of them, because an object present in the index is a promise that its member
table is complete. Three things trigger a rebase, and each is bounded:

- indexing *inside* text a patch wrote -- that text has no anchor coordinate, so
  the first read into a patched value rebases and every read after it is indexed
  again. In the ordinary shape of a run (mods patch at load, the game reads
  afterwards) that is one rebase for the whole session;
- an index entry left inside a region a later patch rewrote, which is refused
  rather than translated: that is the bug the old comment worried about, and the
  one thing this design must never do;
- `EditCeiling` (4096) distinct edited regions.

A rebase is a pass over the index, not a scan of the document -- which is what
makes a mod filling in a table it created itself, where every write puts the next
lookup inside text the previous one wrote, cost a walk of the index rather than a
walk of 41 MB.

## What it costs now

Interleaved A/B on the same tree, median of three pairs.

| | 41 MB imported | 51 KB fixture |
|---|---|---|
| `db_patch` of an existing value | 171 ms -> **6.1 ms** | 0.201 -> **0.012 ms** |
| `db_patch` creating a path | 109 ms -> **12.4 ms** | 0.193 -> **0.057 ms** |
| `db_get` of a deep path, warm | 6 us -> **6 us** | 1 us -> 1 us |
| `db_get` of `templates.items` (12.5 MB) | 1.42 ms -> 1.62 ms | -- |
| `db_get` after a burst of patches | 9-12 us -> **5-6 us** | 1 us -> 1 us |

The residual is the `moveMem`: patching an item early in the document costs
5.2 ms and one late in it 3.7 ms, in the ratio of the bytes that follow them --
about 7.5 GB/s. A patch is now proportional to what follows it rather than to two
copies of the whole document plus a rescan, which is a factor of about 30.

Reads are unchanged, which is the point they had to be. `benchbackend
--keepalive` against the real database, three interleaved pairs: **162 -> 161
requests/second** at the median, `/client/items` ttfb 24.3 -> 23.9 ms, and the
per-phase `db_get` mean 686 -> 674 us. Against the 1000-template generated
database, 817 -> 820 requests/second.

## Boot

`aowlspt-backend` in the install `firstrun` builds -- every mod in the registry,
the 41 MB database the installer imports -- started with an empty store, which is
the boot a player's first ever start actually is. Two pairs, alternated:

| | before | after |
|---|---|---|
| boot to first answer | 2854, 2897 ms | **1690, 1723 ms** |
| `db_patch`, 10 calls | 980 ms | **452 ms** |
| `db_get` during load, 269 calls | 743 ms | **213 ms** |

The `db_get` row is the second half of the same fix: those reads were paying to
rebuild an index the previous write had thrown away.

The ten remaining `db_patch` calls are the mods' *buffered* writes, each carrying
hundreds of folded-in changes, so what is left of them is the merge itself and
the size of the value being merged -- which is the cost a patch is supposed to
have.

**`firstrun`'s own boot number does not move, and that is worth knowing.** It
prints 2893 ms before this change and 2882 ms after. The reason is not the
change: by the time step 8 times a boot, step 7 (`aowlspt-verify`) has already
run a backend against that install, so the mod store is warm and the mods take
their "already done" path. Timed on the same install with the store left in
place, the backend answers in 650 ms and makes **no `db_patch` calls at all**.
So the figure `firstrun` reports as "boot to first answer" is a restart, not a
first run, and the database work it was meant to cover happens one step earlier.
Fixing that is `tools/firstrun.nim`'s to make.

## Does the buffering still earn its place

Partly, and much less than it did. Unbuffered, the same work is about 420 small
patches; at 6 ms each on the 41 MB database that is ~2.5 s, against ~0.6 s for
the ten buffered ones. A mod that dropped its buffering would boot in about three
and a half seconds rather than the fifty-four it faced before: the workaround is
no longer load-bearing, and on a database this size it is still worth about two
seconds. Getting the rest of it would mean holding the document in segments so
that a splice moves no bytes at all, and that puts an indirection under every
byte of `skipValue` and under the 12.5 MB `substr` that answers `/client/items`
-- paying on the request path to save on the load path, which is the wrong way
round.

## Correctness

The merge semantics had to come out byte-identical, so they were checked that way
rather than argued about. A differential harness was built for this pass: a
deterministic script of 400 mixed patches and reads -- top-level tables, paths
that have never existed, paths written by an earlier step of the same run, and
reads of all of them -- run against the old `jsondb` and the new one and diffed,
including the final document's length and checksum and a reload of it.

Identical, byte for byte, on 25 seeds x 3 fixtures and on the 41 MB database.

It found the one bug this design can have. An object whose *value* a patch
replaced keeps its place in the document, so its index entry survives
translation while the member table behind it describes text that is no longer
there -- and a member the patch had just added was looked up in the stale table,
missed, and reported as a path that does not exist. That is precisely the failure
a merge must never produce. Such objects are marked when the patch is applied and
re-indexed on the next lookup (`gDirty` in `backend/jsondb.nim`).

The gates, before and after, same backend build otherwise:

```
emutest    393 ok        393 ok
realtest    90 ok         90 ok   (against the real database)
soak       864 ok        864 ok
fuzzwire   150 ok        150 ok   (its route list is discovered, so the count moves)
allmods     56 ok         56 ok
firstrun   63 checks ok  63 checks ok
```

`allmods` failed three load-order checks on some runs — the registry's
`loadAfter` against a directory walk — and did so identically on both binaries;
they came and went with a mod being rebuilt underneath the run rather than with
anything here.


## A patch racing a read is still undefended, and no gate would notice

Written down because it is the one hazard this pass left open, and an open
hazard nobody has written down is one that gets rediscovered as a bug report.

**Reads take no lock.** That is deliberate and it is most of why the read path
is fast: `/client/items` answers out of a `substr` of the live document, and
putting a lock around it would serialise the largest response the server sends
behind every write. The write path used to rebuild the whole document and swap
it; it now splices in place, which is a `moveMem` of the bytes following the
edit. **The hazard is the same size either way** — a reader walking the document
while a writer moves bytes underneath it — and this pass neither introduced it
nor closed it.

What makes it survivable in practice is the traffic, not the code: SPT is one
player, the writes are small and rare, and the big reads happen at boot and on
menu transitions rather than concurrently with an item move. That is an argument
about the workload, and it stops being true the moment anything drives the
server harder than a single client does.

**`benchbackend` cannot detect it, and this is what it would take.** The tool is
sequential: one connection, one request at a time, `--keepalive` reusing the
socket rather than adding a second. A race needs two requests genuinely in
flight, so catching this would mean a second connection issuing
`/client/game/profile/items/moving` in a loop while the first pulls
`/client/items`, with the large response checksummed against a known-good copy
on every round rather than merely timed. That is a correctness harness wearing a
benchmark's clothes, and it belongs beside `fuzzwire` rather than here — but
`benchbackend` already owns the process spawning, the staging and the wire
client it would need, which is why it is recorded in this file rather than
another.

Re-checked on this tree, so the tool itself is known to work: 3000 templates, a
5 MiB database, one kept-alive connection, 12 rounds of 31 requests — 372
requests in 616 ms, **603 requests/second**, 102 MiB/s of uncompressed body.
`items` 15.5 ms mean, `items/moving` 1.1 ms mean with a p99 of 3.5 ms and a
worst of 24.8 ms. That tail is on the write path and is the one number here a
segmented document would move; the trade that rules that out is written up above
and is not reopened.

# The fourth pass: measure per endpoint, then find there is not much left

This pass started by re-running every number above, because several numbers
elsewhere in this repo had silently drifted and there was no reason to think
these had not. Several had. What follows is what reproduces, what does not, the
instrument that was missing, the three changes that came out of it, and the
ceilings -- because most of what this pass found is that the backend is no
longer where the time goes.

Same method as everything above: `benchbackend` against the real emulator over
the real wire, one pinned `mods/tarkov/bin/tarkov.dll` copied out of the tree
before anything was built, two server binaries from the same sources with the
change reverted in one, interleaved A/B, ports 7071-7080 one run at a time.

## What no longer reproduces

| | recorded above | measured now |
|---|---|---|
| the whole mix, 3000 templates, keep-alive | 1015 req/s | **561 req/s** |
| `store_set` | 43 us | **723-917 us** |
| the `aowl test` floor | `--floor 800` | it is `--floor 500` in `tools/aowl.nim` |
| that configuration's headroom | ~1550 req/s | **~800 req/s**, and one cold run in eight at 268 |
| a `zcache` hit on `/client/items` | ~0.9 ms | **~0.12 ms** at 3000 templates |
| "reads take no lock" | stated at the end of the pass above | no longer true: `jsondb` has a document reader-writer lock, and its own header says so |

The first two rows are one fact. `storeWrite` is an atomic commit now -- value
into a temporary, `MoveFileEx` over the key -- which is the change the section
"The gate went red the same afternoon" measured and then, correctly, declined to
decide. It was decided in `host/common/modstore.nim` afterwards, and the
consequence for the headline number was never written down here. It is now:
**the profile store is two thirds of this server again**, for a stated and
defensible reason, and no throughput number above the "gate went red" section is
still the number this tree produces.

The last row matters for anyone reading the previous pass's closing section: the
hazard it says is open -- *a patch racing a read is still undefended* -- was
closed afterwards by `jsondb`'s document lock. That section is out of date and
this line is the correction.

## The instrument: `--perf` now splits by endpoint

The per-phase totals say the server spent 420 ms in `store_set`. They cannot say
*which endpoint* spent it, and that turned out to be the question every decision
in this pass needed. `/client/items` and `/client/game/profile/items/moving`
have nothing in common except that they are both requests, and a mix containing
both reports a mean belonging to neither. Splitting them was previously done
with arithmetic -- take the aggregate, run a second mix, subtract, divide --
which is an estimate wearing a measurement's clothes, and it is how the `zcache`
row in the table above came to be wrong by a factor of seven.

So a request is tagged with its URL in `aowlspt_nim_handle`, and every phase it
accounts for lands in that URL's row as well as in the total. The class is a
**thread-local index**, not a string: `perfAdd` is called twelve times a request
from sixteen workers and must not hash anything on that path. Slot 0 is "not
attributed", because a thread-local integer starts at zero and charging a thread
that never began a request to whichever URL happens to be first is exactly the
quiet wrong answer this module exists to replace.

`--perf` still costs nothing: 583 and 589 req/s with it, against 579, 564 and
567 without.

## The profile, per endpoint

3000 templates, 20 rounds, keep-alive, 723 requests. Mean microseconds per
request; `route` is net of the host calls it contains, so it is the mod's own
work plus the ABI copies.

| url | n | route | deflate | send | db_get | store_get | store_set | store_list |
|---|---|---|---|---|---|---|---|---|
| `/client/items` | 24 | 6321 | 1515 | 124 | 988 | | | |
| `/client/locale/en` | 24 | 828 | 385 | 59 | 187 | 110 | | |
| `/client/handbook/templates` | 24 | 268 | 182 | 69 | 34 | | | |
| `/client/globals` | 24 | 275 | 59 | 31 | 43 | | | |
| `/client/game/profile/list` | 25 | 145 | 82 | 28 | 0 | 36 | 46 | 260 |
| `/client/game/keepalive` | 23 | 6 | 10 | 22 | | | | |
| `/client/game/profile/items/moving` | 576 | 209 | 28 | 23 | 2 | 13 | **736** | |

And against the real 41 MB imported database, 12 rounds:

| url | n | route | deflate | send | db_get | store_set |
|---|---|---|---|---|---|---|
| `/client/items` (12.5 MB) | 16 | 18649 | 9161 | 495 | 3475 | |
| `/client/locale/en` (2.8 MB) | 16 | 3992 | 4867 | 332 | 904 | |
| `/client/game/profile/items/moving` | 376 | 196 | 28 | 50 | 12 | **1114** |

Two readings, and they are the whole result of this pass.

**The endpoint a player hits thousands of times a session is 1.04 ms, and 70 to
85 percent of it is one file write.** `store_set` is 736 us of it against the
generated database and 1114 us against the real one -- the same number, because
the profile is the same size either way. Everything the backend itself does on
that request is `deflate` 28 us, `send` 23 us, `inflate` 7 us and `match` 1 us:
**59 us, six percent.** There is no change to `backend/` that moves this
endpoint, and the change that would is in `host/common/modstore.nim`, which this
work does not own and which has already priced the trade above.

**`/client/items` is memory bandwidth and nothing else.** 4.25 MB of body, 8.0 ms
to first byte, and the phases account for it as copies: the `substr` out of the
document, the ABI's host buffer, the mod's `takeBuffer`, `envelope`,
`allocBuffer`, `readMem` back into the server, and the cache's compare. That is
the seven copies the first pass counted and could not remove. One of them turned
out to be removable from here.

## The changes

### 1. `db_get` copies the value once instead of twice

`hostDbGet` was `dbGetPath` into a nimony string and then `aowl_out_copy` out of
that string into the host buffer. The string in the middle exists only to be the
argument of the second copy: on `templates.items` against a real database that
is 12.5 MB allocated, copied and freed, per request, for nothing.

`jsondb.dbHoldPath` locates the value and hands back a pointer into the
document's own buffer **with the read lock still held**; `dbRelease` gives it
back. One `aowl_out_copy` happens in between and nothing else does.

**The concurrency argument, because this is a raw pointer into a buffer another
thread may splice.** The document lock is a reader-writer lock and this holds it
*shared*, which is what `dbGetPath` already did -- its `substr` copied under the
same lock, for the same reason: an in-place splice or a growth by a concurrent
`dbPatchPath` under a copy in progress is a use-after-free, not a torn read. The
critical section is therefore no longer than it was; one copy under the lock has
been replaced by a different copy under the lock. A writer takes it exclusive
and so waits for readers, exactly as before. The one new rule is that the caller
must take no other lock and make no other `jsondb` call between the two, and
`hostDbGet` -- the only caller -- does neither. The file's existing order,
document lock first and index lock second and never `cLock` before the document,
is untouched because no second lock is taken at all.

Interleaved A/B, three pairs each, medians:

| | before | after |
|---|---|---|
| `/client/items` ttfb, 5 MiB database | 8.01 ms | **6.77 ms** |
| `/client/items` `route` (mean us) | 6554 | **5131** |
| `/client/items` `db_get` (mean us) | 1036 | **785** |
| `/client/items` ttfb, 41 MB database | 22.76 ms | **16.73 ms** |
| `/client/items` `route` (mean us) | 18649 | **12864** |
| `/client/items` `db_get` (mean us) | 3358 | **2233** |
| `/client/locale/en` `route` (mean us) | 886 | **590** |
| `/client/game/profile/items/moving` `route` | 206 us | 206 us |

Six milliseconds off `/client/items` on a real database, which is more than one
copy of it costs -- removing the string also removes a 12.5 MB allocation and
its page faults. Nothing else moves, which is right: every other body is small.

`backend/dbrace.nim` is extended for it, and the extension was checked the way
that file demands. Every reader pass now reads `templates.items` a second time
through `dbHoldPath` and probes one byte per 4 KB page of the returned range
before releasing, so a freed or spliced buffer is an access violation here
rather than a plausible answer somewhere else. Against this tree: **25754
concurrent read passes against 12481 writes, no torn read, no path lost.**
Against a copy of `jsondb.nim` with `dbHoldPath`'s two lock calls deleted and
nothing else changed: **it fails inside the three seconds**, one read answered
with text that was never in the document. A check that cannot fail is not a
check.

### 2. Request 512 stops lying about the connection

`AOWL_KEEPALIVE_MAX` is applied after the response has gone out, and the note
above records that as deliberate: *request 512 is still answered
`Connection: keep-alive` and the socket still closes under it.* That is a
protocol lie with a measurable cost. A client that believes the header sends
request 513 into a socket the server has already closed and gets nothing back --
**one silently lost request per 512 on every kept-alive connection.**

`benchbackend` has been reporting it on every run long enough to reach it:

```
error 1 of 620 measured requests were not served
  first one: keepalive -> the server closed without answering
```

The server's behaviour is unchanged; what changed is that it says so. A
thread-local set in `aowl_serve_one` before the callback and cleared after it,
read once by `aowlspt_nim_handle`, which clears `req.keepAlive` -- so the header
and the socket agree, and every `return` path already turns `req.keepAlive` into
the poller's keep-or-close answer. Thread-local because a worker answers one
request at a time and sixteen of them do it at once; set and cleared around one
synchronous call on the same thread, so there is no lifetime to reason about and
nothing shared between workers.

Proven on the wire rather than through the benchmark, because `benchbackend`'s
client does not reconnect either way. 513 requests down one socket:

```
baseline    request 1:   Connection: keep-alive      (and 511 more)
            request 513: no answer, socket closed
this tree   request 1:   Connection: keep-alive
            request 512: Connection: close
            request 513: no answer, socket closed
```

Throughput unchanged: 563, 560, 548, 564 req/s before against 580, 591, 520, 587
after, interleaved.

### 3. `hostDbGet`'s redundant local -- no measurable effect

`var v = value` before handing it to `aowl_out_copy` reads as a whole-value copy
and measured as nothing, on three interleaved pairs: nimony was moving it, which
is the same answer the `byref` annotations got in the pass above. It is gone
anyway, because change 1 replaced the block it was in, but it is recorded so the
next person does not spend a run on it.

## What is at its ceiling, and what that means

- **`items/moving`, the endpoint that matters.** 1.04 ms, 59 us of it in
  `backend/`. It does not scale with the database -- 1.04 ms against 5 MiB and
  1.07 ms against 41 MB, which is the index still doing its job -- and it does
  not scale with the profile. The remainder is one atomic file commit, priced
  and argued in `host/common/modstore.nim`.
- **`/client/items`.** 6.8 ms for 4.25 MB and 16.7 ms for 12.5 MB after change
  1. What is left is five copies of the body, four of which are in
  `mods/tarkov` and `aowl/src`. The client's own `inflate` is larger than all of
  it: 14.5 ms round trip against 6.8 ms of server.
- **The compressed-body cache.** A hit on `/client/items` is 120 us at 3000
  templates and about 3 ms at 12.5 MB, and it is the `memcmp` the design
  requires. Sending straight out of the cache entry rather than copying the
  packed bytes out under the lock was costed and not built: it is worth about
  0.4 ms on one boot-time request and it needs a pin count on entries so that an
  eviction cannot free a buffer a worker is still sending from. That is a
  concurrency hazard bought for one percent.
- **`send`, `match`, `inflate`.** 23 us, 1 us and 7 us on the hot endpoint, and
  `keepalive` -- the whole server with an empty answer -- is 38 us. There is no
  fixed overhead left to find.

## The gate

`aowl test` runs `benchbackend --items 1000 --rounds 6 --moves 15 --keepalive
--floor 500`. On this machine that is 783, 826, 788, 812 and 823 requests/second
on five consecutive runs -- and **268 on the first run against a fresh
directory**, which is under the floor. The failure is the store meeting a
directory real-time antivirus has not seen before, not the server; but a gate
that fails one run in eight for a reason its message does not name is a gate
people learn to re-run. It is recorded here rather than adjusted, for the reason
the previous pass gives: a gate moved to accommodate what it caught is not a
gate.

## Correctness

Every suite against the same pinned `tarkov.dll` and the same fixture, before
and after, back to back:

```
                 before              after
emutest          541 ok, 0 failed    541 ok, 0 failed
soak             915 ok, 0 failed    915 ok, 0 failed
fuzzwire         152 ok, 0 failed    152 ok, 0 failed
wstest            62 ok, 0 failed     62 ok, 0 failed
framelen         102 ok, 0 failed    102 ok, 0 failed
realtest         144 ok, 1 skipped   144 ok, 1 skipped   (real 41 MB database)
dbrace           passes              passes, and 25754 of its read passes now
                                     go through `dbHoldPath`
```

# The fifth pass: the commit costs 736 us, and 225 of them bought nothing

The pass above ends by naming its own remainder twice over: *the endpoint a
player hits thousands of times a session is 1.04 ms, and 70 to 85 percent of it
is one file write*, and *the change that would move it is in
`host/common/modstore.nim`, which this work does not own*. This is that file.

Same method as everything above: one pinned `mods/tarkov/bin/tarkov.dll` copied
out of the tree before anything was built, two backends from the same sources
with `modstore.nim` reverted in one, interleaved A/B, ports 7100-7110.

## Why the write is a commit at all

Worth restating before anything is taken off it, because the answer is in this
file and in the module's own comment and it is not negotiable.

The store used to write in place: one handle kept open, overwritten from byte
zero, truncated to the new length. That is 21 us and it is not a commit -- a
process killed between the bytes landing and `setEndOfFile` returning leaves the
file as a mixture of the old value and the new one. What is in this store is a
player's profile, the only thing in the project that cannot be rebuilt from
something else, and a half-written profile is the one loss nothing afterwards
repairs. So `storeWrite` writes a temporary and renames it over the key, and a
reader sees the whole old value or the whole new one.

**That property is kept, in full, by everything below.** What was negotiable was
the price, and a third of it turned out to be buying nothing at all.

## The decomposition

`tools/storecrash --bench` prices the *shapes* a commit could have.
`tests/storeperf` prices the steps of the shape it has, timed inside C around
one system call at a time -- the cheapest step is twenty microseconds and a
millisecond clock reports that as zero. 3 KB value, 300 commits a row, this
machine:

| step | us |
|---|---|
| in place through a held handle -- the floor, and not a commit | **21** |
| create the temporary | 138 |
| write | 76 |
| `FlushFileBuffers` (off by default) | 3400-4500 |
| `MoveFileEx`, `MOVEFILE_REPLACE_EXISTING` and `MOVEFILE_WRITE_THROUGH` | **415** |
| `MoveFileEx`, `MOVEFILE_REPLACE_EXISTING` alone | **218** |
| the same rename through the handle, `SetFileInformationByHandle` | **175** |
| close | 27 |
| the whole thing, through `storeWrite` | **687** |

Three readings.

**It is not the data.** `storeWrite` costs 687, 699 and 688 us for a 3 KB, a
16 KB and an 84 KB value. Every microsecond of it is metadata and scanner, and
none of it is the bytes.

**It is not the `.hist` ring.** That was the obvious suspect and it is innocent:
`storeCommitStats` reports 300 commits for 300 writes, and `backupDue` lets one
snapshot through per key per five minutes. A snapshot costs 650-780 us *when it
happens*, which for a raid's worth of inventory moves is once. The ring is
already amortised correctly and is unchanged by this pass.

**It is not the flush either**, which is the surprise if you read the "gate went
red" section above and stopped there. `gFlushOnWrite` has been off by default
since that section was written, so the 4 ms `FlushFileBuffers` is not in the
736 us at all.

## `MOVEFILE_WRITE_THROUGH` was the wrong half of a pair

Half the rename -- 225 us of a 460 us commit -- was one flag, and it is the one
combination of settings that has no defensible reading.

`MOVEFILE_WRITE_THROUGH` makes the call wait until the **directory change** is
on the disk. `FlushFileBuffers` puts the **file's data** on the disk. The store
was doing the first and not the second: forcing the *name* of the new value out
to the platter while the bytes that name points at were still only in the cache.
A power cut in that window comes back with the key pointing at a file whose
contents never arrived -- which is not "the last write was lost", it is "the
profile is unreadable". Forcing the metadata out sooner cannot make that safer.
It can only make the window easier to hit.

So the flag follows the flush and is not a knob of its own:

| `storeFlushOnWrite` | what happens | what a power cut can do |
|---|---|---|
| `false` (default, unchanged) | no flush, no write-through | cost the last write |
| `true` (`--store-flush`) | `FlushFileBuffers`, *then* `MOVEFILE_WRITE_THROUGH` | nothing |

**No durability switch was added and no default was moved.** The switch already
existed with this default; what changed is that its off position stopped paying
225 us for a guarantee only its on position can actually make. Atomicity is
untouched in both positions, because atomicity comes from the rename being one
filesystem operation and from the page cache outliving a dead process, and
neither flag is involved in either.

## And the rename is asked for through the handle

`MoveFileExW` opens the source by name to get a handle with `DELETE` on it,
renames, and closes. This process has just written that file and is still
holding it. `SetFileInformationByHandle` with `FileRenameInfo` is the same
kernel operation -- `MoveFileExW` is a wrapper over it -- asked for on the
handle that already exists: 175 us against 218. Small, and free.

The temporary is opened with `DELETE` in its access mask for it (`openTemp`),
which is the only thing `winfs.openHeld` did not already ask for.

## What was tried and is not here

- **`ReplaceFileW`.** It moves the displaced file *aside* to a backup name
  rather than deleting it, which would hand the next commit a file to write
  into and remove the 138 us create for good. It costs **1746 us** at 3 KB and
  **15470 us** at 84 KB -- an order of magnitude the wrong way, because it
  copies attributes and streams rather than swapping a directory entry.
- **A temporary name this process has never used before**, on the theory that
  creating over a slot a scanner has just finished with is what the 138 us is.
  The create does drop to 128 us and the rename rises to **560**: 809 us in
  total against 466.
- **`FILE_ATTRIBUTE_TEMPORARY` on the temporary.** Measured as nothing, twice.
- **The temporary beside the key rather than under `.hist`.** 451-478 us, which
  is the same number, so it stays where it is -- one directory holds the things
  that are not keys.
- **A pre-created spare.** Priced by the pass above (`spare + rename + make the
  next spare`, 1351 us) and not re-litigated. Moving the create off the request
  path needs a thread in a module both hosts link, for 138 us.
- **Coalescing writes in a burst.** This is the one that would actually get the
  remaining 400 us, and it is the one the store already removed once, for the
  reason written above `storeWrite`: a process killed outright lost a save it
  had already reported as made. Nothing here reopens it. A store that answers
  "written" before the bytes are committed is not this store.

## The two bugs the measurement walked into

Neither was the errand. Both are the atomic commit's, both have been there since
it landed, and `tests/storeperf/storeguard` reproduces both against the tree as
it was.

### A commit fails outright while the other host is reading the key

A rename that replaces an existing file is refused -- `ERROR_ACCESS_DENIED`, and
no amount of retrying helps -- while **any other process has the destination
open**, `FILE_SHARE_DELETE` or not. That is the Win32 rule and `MoveFileExW`
obeys it.

This module keeps files open. So from the moment the client host has read a key,
every commit the backend makes to that key fails, for as long as the reader's
handle lives -- and *the two hosts running at once against one `<root>/store` is
what the module is for*. `storeguard` prints it in three lines: the writer's
first commit lands, the reader opens the key, and nothing the writer does
afterwards reaches the disk.

```
committed writes: 7689 reads through the held handle, 0 torn, 1 distinct value;
                  the file itself moved through 1
error the writer was actually writing: the file never changed
      could not replace ...\profile.guardtest (error 5)
```

`FileRenameInfoEx` with `FILE_RENAME_FLAG_POSIX_SEMANTICS` is that rule lifted:
the destination is unlinked rather than required to be unopened, exactly as
`rename(2)` has always behaved. Windows 10 1809 and NTFS, and where it is
refused the code falls back to the classic rename and then to `MoveFileExW`,
which is what the store did before.

### A held handle never sees the other host's commit

The second half of the same fact, and it survives the first being fixed. A
handle follows the **file**, not the name. A commit gives the name to a
different file, so a reader holding the key has a handle to a file that has been
unlinked -- and answers every later read with a value that was true once. Not
stale by a race: stale for as long as the handle lives, which is until the
32-entry LRU gets round to it.

That invalidates the argument the handle cache was built on, which is in this
file two passes up: *this is not a cache of the contents, and the difference is
the whole reason it is safe... every read still goes to the file, so a write by
the other host is seen exactly as it is seen today*. It was true when the write
was an in-place overwrite. It stopped being true when the write became a rename,
and nothing said so.

An unlinked file has no links, and `GetFileInformationByHandle` says so without
opening anything -- which is the point, because an open is the 890 us the handle
cache exists to avoid. `heldFor` checks it and reopens when the answer is zero.
It costs about 7 us on a 13 us read, and `store_get` on the item-move endpoint
goes 13 -> 20 us for it. That is the price of the cache being a cache of handles
rather than a cache of values, which is what it always claimed to be.

## What it costs now

`tests/storeperf`, same machine, 300 commits:

| | before | after |
|---|---|---|
| `storeWrite`, 3 KB value | 687 us | **423 us** |
| `storeWrite`, 84 KB value | 676 us | **449 us** |

Through the server, 3000 templates, 20 rounds, keep-alive, `--perf`:

| | before | after |
|---|---|---|
| `items/moving` `store_set` | **718 us** | **476 us** |
| `items/moving` `store_get` | 13 us | 20 us |
| `items/moving` mean | 1.171 ms | **0.897 ms** |
| `items/moving` p50 | 1.074 ms | **0.885 ms** |
| `items/moving` p99 | 1.697 ms | **1.102 ms** |
| `store_set` across the run | 428.2 ms / 581 calls | **281.0 ms** / 581 calls |
| `route` across the run | 736.0 ms | **598.3 ms** |

Eight interleaved pairs of the whole mix, one connection, same pinned mod:

```
before   611 608 611 605 606 597 540 571      median 606   best 611
after    682 499 606 675 688 693 663 689      median 682   best 693
```

Two of the "after" runs and two of the "before" runs carry a 70-200 ms outlier
on a single request; the machine had three other builds on it and the spikes
land on both binaries, so the honest statistics are the median and the best.
**+13%**, and the reason it is not +35% is that this mix is dominated by
`/client/items` at 13 ms a request, which this change does not touch.

The gate configuration -- `--items 1000 --rounds 6 --moves 15 --keepalive
--floor 500` -- is where the endpoint's share is largest, and it is also the one
the build fails on. Eleven cold runs a side, each against a directory that has
never existed before:

```
before   837 860 819 840 841 832 826 870 854 846 820      median 840
after    961 990 961 1021 929 939 1006 978 934 963 951    median 961
```

**840 -> 961 requests/second, and the floor is 500.** The margin goes from 1.68x
to 1.92x.

**The 268 did not reproduce.** The pass above records one cold run in eight
coming in under the floor; twenty-two cold runs against fresh directories were
taken here, eleven a side, and the lowest was 819. That is not a refutation --
the run that produced 268 was a real run and the mechanism it names (the store
meeting a directory real-time antivirus has not seen) is real -- but it is not
reproducible on this machine today, and a floor now 1.9x under the median is the
answer to it rather than moving the floor. The floor stays at 500.

## Correctness

Three gates, each run against the tree before this work as well as after,
because a gate that has only ever been run one way is a gate nobody has seen
fail.

**`tools/storecrash --rounds 60`** -- kills a process inside a write and demands
the file be one whole value.

```
this tree   in place (the control): 3 of 60 kills left a torn file
            the store as it is:     0 of 60 torn, 23 kills landed inside a commit
            ok  8 checks over 60 kills a phase
```

The 23 is the coverage claim: a temporary still sitting there after the kill is
proof the kill happened inside a commit. A run where none did would pass and
would mean nothing, and it is asserted for that reason.

**`tests/storeperf/storeguard`** -- new, and the one this pass needed. A child
process writes a key while this process reads it, and every read has to be
exactly one whole value *and* the sequence of values a reader sees has to move.
A reader that keeps answering `n=2` while the writer is on `n=900` has not torn
anything; it has stopped being a reader. A second phase runs the same thing
against the in-place write the store used to do, which is where the torn reads
come from -- the check can fail, which is what makes the first phase's silence
worth something.

```
against HEAD    error the writer was actually writing: the file never changed
                error a reader keeps up with a committed write: the held handle
                      answered 1 distinct value while the file moved through 1
                2 of 9 checks failed

this tree       committed writes: 25762 reads through the held handle, 0 torn,
                                  4 distinct values; the file moved through 4
                in-place writes:  26839 reads, 8 torn
                ok  9 checks over two phases of 4s
```

It also holds the `.hist` ring to what the module promises: at most three
generations for a key, every one of them a whole value, and none of them
reported by `storeKeys`.

**`emutest`**, both backends against the same pinned `tarkov.dll`, the same
fixture and a fresh store each:

```
before   3 of 565 failed
after    3 of 565 failed   (the same three)
```

The three are the emulator's own in-flight quest-condition work -- a kill
condition's counter reading -1 -- and both binaries fail them identically.

## The hazard this pass leaves open

**Two processes committing the same key share one temporary name.** The
temporary is `<dir>/.hist/<key>.tmp`, which is per key and not per process, and
it is opened with every share flag set. Two hosts committing the same key at the
same moment can therefore interleave their writes into one temporary and rename
a mixture of the two values over the key -- which is the one thing this module
exists to prevent, arriving from a direction its lock does not cover, because
the lock is per process.

It is not reachable today: the two host sides write disjoint keys, and
`storeguard` had to put both roles on one key deliberately to get near it. The
fix is a per-process suffix on the temporary -- `<key>.<pid>.tmp` -- which is
free, because it is a name this process reuses rather than a new one each write,
and the new-name-each-write variant is the one measured above as slower. It is
not made here because `tools/storecrash` asserts on the exact name `<key>.tmp`
as its coverage evidence, and the two edits belong in one commit rather than in
two agents'.
