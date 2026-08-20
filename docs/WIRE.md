# The wire format

What a post-1.0 Escape From Tarkov client puts on the wire, in both directions,
and how this server reads and writes it.

Everything here is measured against a capture of a complete real session
against BSG's live backend — `mods/tarkov/data/capture/raid1`, 220 requests,
client build `1.1.0.1.46777`, taken 2026-08-20. Route numbers below are that
capture's Fiddler sequence numbers. Nothing in this document is inferred from a
guess about what BSG "probably" does; where something is not known, it says so.

## The short version

    wire = shuffle_L( [int32 LE size][payload of `size` bytes][trailing junk] )

    payload, requests:   zlib(json)
    payload, responses:  [16-byte IV][AES-192-CBC( zlib(json) )]

The outer layer carries **no key**. The inner layer, on responses only, does.

## The envelope

`shuffle_L` is a Fisher-Yates permutation over the whole buffer. Its swap
indices come from a linear congruential sequence stepped by the buffer's own
length — the length is the only input, so anyone holding the bytes can undo it.

    j(i) = ((1624453 * (0x65F6D + i + len % 0xAAB) + 1023920427) % 0x8ED7A18D) % i

applied ascending for `i` in `1 ..< len` to unshuffle, and descending to
shuffle. The client builds this as a table of `len + len % 0xAAB` entries and
indexes the tail of it; the closed form above is the same permutation without
the allocation, and `tests/bsgwiretest.nim` asserts the two agree.

This is the same permutation the repository already used for `/client/metadata`
response bodies (`tools/metablob.py`). The discovery was not the permutation —
it was that it is on **every** route, in **both** directions.

### The trailing junk

`size` covers the payload. Whatever follows it inside the buffer is the tail of
the client's send buffer, left unwritten, and means nothing.

It explains something that looked like cryptography and was not. The same
logical request appears on the wire at ten different lengths, because the junk
length varies — and since the length picks the permutation, ten different
lengths means ten completely different-looking bodies for one request. Two
routes that send the same empty body will produce byte-identical wire bodies
whenever they happen to land on the same length, which is why
`/client/weather` and `/client/game/keepalive` post identical bytes in the
capture. Neither fact is a signal about the route.

## Requests

Every game request body is `shuffle( [size][zlib(json)] )`. **Requests are never
encrypted** — the client has no encrypt method at all; `HTTPTransportManager`
implements only `Decrypt` and `DecryptFromBytesAES`.

Three exceptions, all of which the server must still read:

| route | framing |
|---|---|
| `/client/metadata` | plain JSON, no envelope, no compression |
| `/client/libraries`, `/client/libraries-extra` | envelope over **raw JSON**, not zlib |
| `/launcher/analytics` | plain `zlib(json)`, no envelope |

## Responses

Responses whose headers carry `X-Encryption: aes` are
`shuffle( [size][ [16-byte IV][AES-192-CBC ciphertext] ] )`, and the decrypted
plaintext is `zlib(json)`.

* **Key**: `7*YabV3MfOfyE*lhI*l*Qx*q` — 24 ASCII characters, used **directly**
  as the 24 key bytes. Not hashed, not base64- or hex-decoded. It is IL2CPP
  string literal 2981, built into `HTTPTransportManager`'s static constructor.
* **IV**: the first 16 bytes of the payload, fresh per response.
  `HTTPTransportManager.IV_LENGTH` is 16, and every call site passes a null IV
  argument, meaning "take it from the buffer".
* **Mode**: CBC. Confirmed by the client's code and corroborated by the corpus —
  routes captured several times at identical ciphertext length share no blocks.

Verified against all 171 encrypted bodies in the capture, 0 failures.

Responses that are **not** encrypted: `/client/game/keepalive` and
`/launcher/game/start` are plain `zlib(json)` with no envelope;
`/client/libraries` answers a bare `{}`; `/client/metadata` answers a shuffled
envelope over raw JSON. `/client/libraries-extra` is the odd one — AES with
**no envelope at all**, 96 bytes bare.

### What this server sends

This server replies in plain `zlib(json)` with no envelope and no
`X-Encryption` header, and the client accepts it. That is not an accident of
ours: the client honours the header rather than requiring encryption, which is
why `/client/game/keepalive` can be plaintext on the real backend too. The
emulator therefore never needs the key to *serve* — only to *read* a capture.

## Why any of this mattered

The server inflated request bodies and never unshuffled them. A shuffled body
is not zlib-framed, so it took the pass-through branch of `inflateBody` and
arrived at the route handler as noise — with a 200, and no warning anywhere.

Every route that ignores its request body kept working. That is most of the
menu, so a real client booted all the way to the character-selection screen
against a server that had never read a single thing it was sent. What broke was
everything that mattered: creating a profile, moving an item, ending a raid.

The lesson is not "we missed a layer". It is that **the failure had no
symptom at the layer it happened at**. The 200s were real, the log was clean,
and the boot got further than it had any right to.

## Reading a body

`tools/bsgwire.py` decodes anything from a capture:

    python tools/bsgwire.py decode <file>            # one body, identified
    python tools/bsgwire.py scan <capture-dir>       # classify a whole capture
    python tools/bsgwire.py extract <capture> <out>  # decode all of it to .json
    python tools/bsgwire.py selftest --capture <dir>

`decode` names what it found rather than guessing: `plain-json`, `plain-zlib`,
`wrapped-zlib`, `wrapped-json`, `wrapped-aes`, `bare-aes`, or `unknown`. It
tests JSON by parsing it rather than by looking at the first byte, because one
ciphertext byte in 128 is `{` and a misfiled ciphertext is worse than an
unclassified one — it is a body the caller believes it has read.

`tools/bsgaes.py` is the AES, standard library only (this machine has no pip),
checked against the FIPS-197 known-answer vectors for all three key sizes.

## Reading a body, in the server

`backend/wire.nim` has `bsgUnshuffle`, `bsgShuffle` and `bsgUnwrap`, and
`aowlbackend.inflateBody` applies them. The order it tries things in is
load-bearing:

1. if the body **looks** zlib-framed, try a plain inflate;
2. otherwise, or if that failed, try the envelope;
3. otherwise, if it did not look framed, try a plain inflate anyway;
4. otherwise pass it through — unless it claimed to be framed, in which case
   refuse it with a 400.

Step 2 running after a *failed* step 1 is not defensive coding. `looks_framed`
reads two bytes, so about one shuffled body in five hundred opens with a valid
zlib header by chance — and one of the 149 in the capture does (seq 458,
`/client/mail/dialog/list`). Deciding on the header alone sent that body down
the plain path, where the inflate failed and it fell out of the function as
noise. The gate covers exactly that case.

## Recapturing

The format is not version-specific in its shape, but the **key is a literal in
the client binary** and can change with any patch. To recapture: filter Fiddler
to the backend host, play from the launcher to wherever you need, save the
sessions as a `.saz`, and decode with `tools/bsgwire.py`. If the key has moved,
it is recovered by disassembling `HTTPTransportManager::.cctor` — see
`tools/METABLOB.md` for how the metadata is decrypted first, since that is what
makes the client's own type and method names readable.

## What is not known

* Whether the client would *accept* an encrypted response from us. We have
  never sent one, because we have never needed to.
* Whether the key is per-build, per-branch, or has been stable across builds.
  We have exactly one build's worth of evidence.
* `/client/libraries-extra`'s framing, beyond "AES, 96 bytes, no envelope". Its
  request is an envelope over raw JSON, so the asymmetry is real but
  unexplained.
