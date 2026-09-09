# metablob.py

Obtain and install the Escape from Tarkov `/client/metadata` **section-layout
blob** that aowlspt's emulator must serve so a post-1.0 client can finish
decrypting its own IL2CPP `global-metadata.dat`.

This is offline interop on an owned binary. **The tool makes no network calls.**
It reads BSG's own game files and (for the capture path) a Fiddler capture the
user already made, and writes one small JSON into `mods/tarkov/data/metadata/`.

Faithful port of the reference tool **XM-MetadataDecrypt** (MIT):
`eft_metadata_key/core.py` (offline header transform) and
`gui/MetadataDecryptGui/MetadataDecryptor.cs` (full decrypt pipeline, used here
only to verify a recovered layout).

## Run it on Windows

    python tools/metablob.py <subcommand> ...

Stdlib only, no dependencies. It runs anywhere, **but the request key and the
capture subKey derive from the metadata file's on-disk _creation_ time**, and
only Python on Windows reports that reliably (`st_birthtime`, or `st_ctime`
which is creation time on NT). On WSL/Linux the DrvFs `st_ctime` is *change*
time, so any subKey / `metadataRequestKey` computed there is wrong. `derive`
prints a warning when not on Windows. Version and internalKey do **not** depend
on time and are correct anywhere.

### Creation-timestamp caveat (read this)

The subKey is `TransformKey(creation_FILETIME_low32) % 0xA + 5`, i.e. one of ten
values 5..14, keyed by the *creation time of the very file on disk*. Copying,
extracting, or re-downloading `global-metadata.dat` gives the copy a **new**
creation time and therefore a different subKey. **Do not copy the .dat before
deriving -- always point the tool at the original file inside the game install.**
(This only affects the request key and the local capture subKey; it never
affects the stored blob, which is subKey-independent -- see below.)

## What gets stored, and why it is portable

The blob installed at `mods/tarkov/data/metadata/<version>.json` is:

    { "version": "1.1.0.1.46777", "internalKey": "0x876F9333", "valueHex": "<hex>" }

`valueHex` is the **UN-shuffled raw layout**: a sequence of 16-hex-char records,
each `DataSize` (8 hex) then `DataOffset` (8 hex), big-endian. This raw layout is
**version-constant -- identical for every player on a given build.**

BSG's live server does not return this raw form. It returns the raw layout
*shuffled* by a per-client subKey (an ascending Fisher-Yates permutation of the
hex string, keyed by `TransformKey(subKey)`). Because subKey is derived from each
machine's own file creation time, the shuffled value differs per install, which
is why a `/client/metadata` response is single-use and per-session.

So the division of labour is:

* **This tool stores the raw (un-shuffled) layout.** A capture taken on *any*
  install of the same version yields the same raw layout, so captures are
  **portable across machines** -- you do not need the exact capture from your own
  install.
* **The emulator route re-shuffles** the stored raw layout for each connecting
  client, using that client's own subKey (which the runtime recovers from the
  posted request `key` against the known `internalKey`), by applying the inverse
  (descending) permutation -- `unshuffle_layout_hex` in this module -- so the
  client's own ascending shuffle recovers the raw layout.

## Subcommands

### `derive <gamedir>`
Offline. Reverses the small BSG header transform (XOR the first `0x200` bytes
against the next `0x200`, nibble-shuffle the header-pointed words) and prints
`gameVersion`, `internalKey`, `subKey`, and `metadataRequestKey`. Reads only;
decrypts nothing else.

    python tools/metablob.py derive "D:\Games\Tarkov"
    #  gameVersion 1.1.0.1.46777 / internalKey 0x876F9333 / requestKey 3132852448

### `extract-capture <gamedir> <capture.txt>`
The main path. Give it a Fiddler **"Request & Response as Text"** export and the
game dir. It:
1. finds the *last* `/client/metadata` request and its `HTTP/1.1 200` response,
   slices the body by `Content-Length`, and deshuffles it (length-keyed byte
   permutation, no gzip/AES) to plain JSON, then reads `data.value`;
2. recovers the raw layout by **trying all 10 candidate subKeys (5..14)** and
   keeping the one whose parsed `(DataSize, DataOffset)` records are sane
   (offsets strictly ascending and every section within the file). This is what
   makes a capture from someone else's install work -- their subKey is unknown,
   but the raw layout it recovers to is the same as yours;
3. **verifies** by re-shuffling the raw layout to *this* install's own real
   subKey and running the full decrypt through the real code path, asserting the
   output begins `AF 1B B1 FA`, then `1F 00 00 00` (IL2CPP format v31), and
   contains readable type names like `System.Object`;
4. on success, `install`s the raw layout.

### `from-metadata <decrypted.dat> <version>`  (experimental)
The no-capture path, for when someone publishes a decrypted `global-metadata.dat`
(or an Il2CppDumper output). A decrypted file begins with the standard
`Il2CppGlobalMetadataHeader` -- `uint32 magic`, `uint32 version`, then the section
table as `(offset, size)` int32 pairs -- so we read the 31 relocatable sections
and emit them as `(size, offset)` records in the blob's 16-hex encoding, then
re-derive to confirm the encoding round-trips.

**Limitation (important):** BSG's real blob is **not** the full 31-section
header. It is a version-specific *subset* -- observed 1.0.x captures carry **13**
or **18** records, not 31 -- chosen by an internalKey-derived permutation and
stripped out of the encrypted file. From a decrypted file alone, neither the
subset nor its size is recoverable, so a blob produced this way will very likely
**not** satisfy a real client and cannot be runtime-verified here. Prefer
`extract-capture`. This subcommand stores `internalKey` as `0x00000000`
(placeholder -- fill it in from `derive`).

### `install <version> <blob-or-hex> [--internal-key 0x...]`
Writes `mods/tarkov/data/metadata/<version>.json` in the format above. `blob`
may be raw hex, a file of raw hex, or an existing blob JSON. Validates that the
hex parses and its length is a multiple of 16.

### `status <gamedir>`
Prints the install's `gameVersion` / `internalKey` and whether
`mods/tarkov/data/metadata/<version>.json` already exists.

### `selftest [gamedir]`
Asserts `D:\Games\Tarkov` (default) derives to `1.1.0.1.46777` / `0x876F9333`.

### `test`
Self-contained unit tests, no game files needed:
* shuffle/deshuffle are exact mutual inverses for every subKey 5..14;
* subKey is always in [5, 14];
* `TransformKey` reproduces the live install's request key
  (`internalKey 0x876F9333`, subKey 12 -> 3132852448);
* the three cached 1.0.x `value` blobs are each a multiple of 16 hex chars and
  parse to `(size, offset)` records (208->13, 288->18, 288->18). **These cannot
  be full-decrypt-verified -- we have no 1.0.x game file** -- the test says so;
* a synthetic Fiddler capture round-trips through the parse + body-deshuffle +
  Content-Length path.

## End-to-end flow: capture -> install -> serve

1. In Fiddler, filter to `gw-pvp.escapefromtarkov.com`, start the real game, and
   let it reach the main menu. The client calls `/client/metadata` once during
   `il2cpp_init`.
2. Select that session, **Save > Selected Sessions > Request & Response** as a
   `.txt`. Do not edit it (a text editor changing line endings corrupts the
   shuffled body and the deshuffle sanity check will reject it).
3. Run `python tools/metablob.py extract-capture "D:\Games\Tarkov" capture.txt`.
   It verifies against your real `global-metadata.dat` and installs the blob.
4. The emulator's `/client/metadata` route reads
   `mods/tarkov/data/metadata/<version>.json`, re-shuffles `valueHex` for the
   connecting client's subKey, and returns `{"data":{"value":"<shuffled>"}}`.

A Tarkov update is then a two-minute chore: capture once, `extract-capture`,
done -- the blob is portable to anyone else on that version.

## What is verified vs. not

* Verified: offline derive on the live install (`1.1.0.1.46777` / `0x876F9333` /
  requestKey `3132852448`); shuffle/deshuffle inverse property; subKey range;
  `TransformKey` against the live request key; capture parse + body deshuffle +
  Content-Length; blob install format (LF, no BOM).
* **Not** verified, and the tool says so: full decrypt of any 1.0.x blob (no
  1.0.x game file); a full extract-capture verify for 1.1.0.1.46777 (needs a real
  capture -- none is checked in); any `from-metadata` output at runtime.
