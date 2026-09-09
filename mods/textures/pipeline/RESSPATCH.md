# In-place texture replacement — `resspatch.py`

> **STOP. READ THIS PARAGRAPH.**
> The `.assets` and `.resS` files inside `D:\Aowlspt\EscapeFromTarkov_Data` are
> **not copies**. They are *the same files on disk* as the ones in the real
> Tarkov install at `D:\Games\Tarkov` — Windows hardlinks, two directory names
> pointing at one blob of bytes. If you write to the aowlspt one, you have
> written to the user's real game. There is no undo at the filesystem level and
> the real install is not ours to break.
>
> Break the link first (`resspatch.py unlink`), which copies the file to a new
> blob and swaps it in. It costs ~294 MB of disk and about a minute, once.
> Every verb in this tool that writes **refuses to run** while the target still
> reports more than one link, so the safe path is also the default one.

## What this does, and why it can work at all

The mod that swaps textures at runtime is one route. This is the other: edit
the shipped asset bytes directly, before the game ever loads.

`sharedassets2.assets` (Factory) describes 292 `Texture2D` objects. It does not
contain their pixels — every one of them is *streamed*, with an explicit
`offset` + `size` into the sidecar `sharedassets2.assets.resS` (224.3 MB of the
258.4 MB file). The payloads are densely packed: no overlaps, 22 gaps totalling
179 bytes.

That density is the whole reason this is possible. There is no room to grow a
texture. But a block-compressed payload's length is a pure function of
`(width, height, format, mipCount)` — so an image with the **same dimensions and
the same format** is **byte-for-byte the same length**, and can be dropped in
place with no offset in the `.assets` file needing to change at all. Measured:
290 of the 292 lengths reproduce exactly from the descriptor.

The 2 that do not are `container` and `container_nrm`, both **DXT5Crunched** —
entropy-coded, so their length depends on the *content*. They can never be
overwritten in place. The tool refuses them by name.

## The consistency check

`D:\Aowlspt\ConsistencyInfo` lists every shipped file with a `Size` and a
`Checksum`, and the client refuses to boot if either is wrong. The checksum is
a plain **byte-sum mod 2^32, stored as a signed int32** — verified against the
shipped values for both files. Because our writes are length-identical, only
`Checksum` ever needs updating, and only for the `.resS`. That is `resync`.

(`Logging.config` in §7 of `CLAUDE.md` is a different instance of the same
landmine. Same rule: re-sync the manifest entry or the client will not start.)

## Python

`enumerate` and `verify-length` need **UnityPy**, and UnityPy is installed
**only under the Microsoft Store Python** — *not* the msys `python` that is
first on `PATH`. Use it explicitly:

```
"%LOCALAPPDATA%\Microsoft\WindowsApps\python.exe" resspatch.py enumerate ...
```

`unlink`, `write`, `restore` and `resync` are pure stdlib and run under any
Python 3.9+; they read the index JSON cached next to the `.assets`. If you get
the interpreter wrong the tool says so by name and exits — it does not guess.

## The flow

```powershell
$py = "$env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe"
$A  = "D:\Aowlspt\EscapeFromTarkov_Data\sharedassets2.assets"
$R  = "$A.resS"

# 1. look
& $py resspatch.py enumerate $A --filter concrete

# 2. SAFETY GATE — must PASS before anything is written
& $py resspatch.py verify-length $A

# 3. break the hardlink (once per file, ever)
& $py resspatch.py unlink $R $A

# 4. author a replacement at the exact same size/format, then write it
& $py makedds.py --w 1024 --h 1024 --format dxt5 --solid 255,0,255 -o magenta.dds
& $py resspatch.py write $A --texture concrete_cracks --dds magenta.dds

# 5. re-stamp the manifest
& $py resspatch.py resync D:\Aowlspt\ConsistencyInfo $R

# 6. undo, byte-for-byte
& $py resspatch.py restore $A
& $py resspatch.py resync D:\Aowlspt\ConsistencyInfo $R
```

### The verbs

| verb | what it does |
| --- | --- |
| `enumerate <assets>` | every `Texture2D`: name, format, dimensions, mips, offset, length, and albedo/normal/gloss/mask per fact #69. `--json` writes an index; `--filter` narrows. |
| `verify-length <assets>` | recomputes every payload length from its descriptor, reports mismatches, overlaps and gaps. Non-zero exit on any mismatch. `write` runs this itself and refuses on failure. |
| `unlink <path>...` | copy → verify byte-identical → atomic swap. Prints link count and inode before and after, and fails loudly if links did not drop to 1 or the inode did not change. |
| `write <assets> --texture N --dds F` | refuses unless: link already broken (both files), exactly one texture by that name, not Crunched, streamed, and format + dimensions + **length** all match exactly. Never pads, never truncates. Journals the original bytes, then reads back what it wrote. |
| `restore <assets> [--texture N]` | replays the journal newest-first, restoring the original bytes. Refuses (INCONCLUSIVE) if the bytes on disk are not the ones it wrote — it will not clobber someone else's edit. |
| `resync <ConsistencyInfo> <file>...` | recomputes Size + Checksum. `--check` reports without writing. |

`restore` is the verb to trust first. Every `write` saves the original span to
`.resspatch/<name>.<offset>.<ms>.orig` next to the `.resS`, with SHA-256 of the
bytes before and after, so a restore is verifiable rather than hopeful.

### Authoring replacements

`makedds.py` builds solid-colour and pseudo-random DXT1/DXT5 DDS files with a
full mip chain, no image library needed. For real art, any DDS with a matching
fourCC/DXGI format, matching dimensions and a complete mip chain will do —
`write` checks all three and tells you the exact byte delta if the length is
off. Per fact #69: albedo is `_D/_d/_dif/_diffuse/_Albedo/_A/_A2/_c` or a bare
name, normals are `_n/_nrm/_nm/_normal` and are **always DXT5**, and `_G` is
**gloss, not roughness** — an ambientCG `_Roughness` map must be inverted first.

## Proven, and not proven

Proven on a scratchpad copy (never the live install):

1. `verify-length` reproduces **290/292** lengths, 0 mismatches, and names the
   two DXT5Crunched textures as never-writable.
2. A magenta 1024×1024 DXT5 write lands at offset 9350160: all 87,383 blocks
   read back identical to the intended block, file size unchanged, neighbouring
   payloads untouched, `verify-length` still clean.
3. A 64-byte-short input, a 512×512 input and a DXT1 input are each **REFUSED**
   with the exact delta; the `.resS` hash is unchanged after all three.
4. `container` (DXT5Crunched) is **REFUSED**.
5. `resync --check` reproduces the shipped `Size`/`Checksum` for both files
   exactly (`-1012104931` and `2083831699`), and after the write reports
   `2083831699 -> 1997826187`.
6. `restore` returns the `.resS` to SHA-256
   `BF166971…6C1EEA38` — byte-identical to the pristine original — and refuses
   with INCONCLUSIVE when a single byte in the span was changed by someone else.

**NOT proven: that the game renders the replaced bytes.** That is the one step
this tool cannot check, and no amount of hash-matching substitutes for it.

### The live test, exactly

Run on the aowlspt install only, after `unlink`:

1. Write `concrete_cracks` (1024×1024 DXT5, offset **9350160**, length
   **1398128**) as flat magenta. `resync`. Launch, enter Factory, look at
   concrete.
2. Then — and this is the part that must not be skipped — write the same
   texture as the **length-correct garbage** control
   (`makedds.py --noise 1`, same 1398128 bytes) and look again.

The negative control is what makes the result readable. Magenta appearing is
suggestive; garbage appearing where magenta appeared is proof the client is
reading *our* bytes at *that* offset. Magenta **not** appearing means nothing on
its own — the material may not be on any visible surface — and per fact #50 the
failure mode to fear is exactly "the game ignored me" masquerading as "my write
did not land". If neither the magenta nor the garbage changes anything on
screen, the verdict is **INCONCLUSIVE about the write** and the next question is
whether Factory loads `sharedassets2` at all — not whether the bytes are there,
which is already settled.

Afterwards: `restore`, then `resync` again. Leaving a patched `.resS` with a
stale `ConsistencyInfo` is a client that will not boot.
