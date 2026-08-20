# `/client/metadata` section-layout blobs

Post-1.0 `GameAssembly.dll`, inside `il2cpp_init`, POSTs to `/client/metadata`
to obtain the section-layout blob it needs to decrypt its own IL2CPP metadata.
Without a correct answer the client dies at about 200 ms, before the normal
session pipeline has even started. The route lives in `mods/tarkov/tarkov.nim`
(`onMetadata`); its math is `mods/tarkov/emu/metadata.nim`.

This directory holds one blob per game version:

    <version>.json      e.g. 1.1.0.1.46777.json

Each file is:

```json
{
  "version": "1.1.0.1.46777",
  "internalKey": "0x876F9333",
  "valueHex": "<raw, un-shuffled section layout as one hex string>"
}
```

- `internalKey` is the per-version constant the client bakes into its own
  metadata file. The server uses it, with the `key` the client sends, to recover
  which of the ten possible sub-keys (5..14) this install derived from its
  metadata file's creation timestamp -- so one blob answers **every** install of
  that version regardless of local timestamp.
- `valueHex` is the **raw, un-shuffled** layout: a run of 16-hex-char
  `(DataSize, DataOffset)` records. The server re-shuffles it per request against
  the recovered sub-key, so the client's own deshuffle reproduces exactly these
  bytes. Do not pre-shuffle it here.

## Producing a blob

Blobs are **not committed and not released.** A blob is derived from your own
Tarkov install (it reads that install's `global-metadata.dat`), so it is local,
per-version output. `tools/metablob.py` installs one:

    python tools/metablob.py --game "D:\Games\Tarkov" --out mods/tarkov/data/metadata

If a version's blob is absent, the route logs an explicit error naming the
version and this tool, and answers an error envelope -- it never fabricates a
layout, because a wrong layout does not fail at the route, it fails much later
and much more confusingly when the client tries to decrypt with it.
