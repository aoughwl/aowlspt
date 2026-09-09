# Installing

From a Tarkov install the official launcher maintains, to a modded one you can
start: seven steps, in order, and what to do when one of them refuses.

This is the order somebody actually walked, not an idealised one. `tools/firstrun.nim`
walks the same order automatically — a synthetic client, `payload`, what the
payload declares, `plan`, `install`, `importdb`, `verify`, the client's boot
sequence, a mod switched off and on, a restart — and asserts each step, so the
day one of them stops working it is caught at the step that broke it. It prints
ten numbered steps and **64 checks** (run 2026-08-19; this paragraph named eight
of the ten and no count at all):

```
installer\build\firstrun.exe --scratch C:\scratch\firstrun
```

It writes nothing outside `--scratch`, and it exits 0 with an explanation when
there is no SPT install to import a database from. It is a repository tool and
is not in the release archive: it builds a client fixture with a compiler.

**This document ships inside the release archive as well as living in the
repository, and the two are laid out differently.** If you extracted a `.zip`,
you can skip step 2 entirely — the payload is already built and already in
front of you — and the tools are one directory over from where the commands
below say:

| | you extracted `aowlspt-<version>.zip` | you cloned the repository |
|---|---|---|
| the tools | `install\` | `installer\build\` |
| the payload | `payload` | `installer\payload` |
| step 2 | skip it | do it |

So `detect` is `install\aowlspt-install.exe detect` from the archive and
`installer\build\aowlspt-install.exe detect` from the repository. Commands are
written the repository's way below; substitute if you downloaded.

## What version is this

One line in `VERSION`, at the top of the archive and at the top of the
repository, and that number is the whole release: the archive is named after
it, `MANIFEST.sha256` is headed with it, the `payload.json` inside the archive
carries it, and `aowlspt-install` writes it into `aowlspt-install.txt` so a
finished install can still say which build it is. `aowlspt-verify` prints it
back. Nothing else versions the bundle — the numbers in `registry/mods.json`
version individual mods and move independently.

It is not a Tarkov version. `targetTarkovVersion` in `payload.json` is that,
and the two are unrelated numbers that appear on the same screen.

## Read this part first

**Nothing in this project has ever been run against BSG's real client.** The
host, the launcher and the injector have been exercised against a stand-in
IL2CPP runtime and against synthetic installs built for the purpose; the game
itself has not been in the loop. The first time anyone points this at a real
`EscapeFromTarkov.exe` will be the first time. Expect that to show.

**The client this produces must never talk to the live service.** The installer
does not carry BattlEye across and the launcher does not start it, because the
modded client plays against a backend on your own machine. Injecting a DLL into
a process that is talking to BSG's servers is a decision with consequences for
your account, and it is yours to make, not ours to make for you by omission.
The tools here do not stop you pointing the client at something else. They also
will not help you.

**Your existing install is only ever read.** Everything is built in a second
directory. If any of this goes wrong, delete that directory; the 78 GB the
launcher maintains is untouched and still updatable.

## What you need

- A **post-1.0** Escape From Tarkov install (1.0.0 or later). Pre-1.0 clients
  are not supported and cannot be made supported — see [Refusals](#refusals).
- About 1 GB of free disk on the same volume as that install. Not 78 GB: the
  asset bundles are hard linked rather than copied.
- Windows. Nothing else — no .NET runtime, no PowerShell, no Python.

To build the payload yourself you also need [msys2's ucrt64
toolchain](https://www.msys2.org/) and a [nimony](https://github.com/nim-lang/nimony)
checkout at `%USERPROFILE%\nimony`. If someone handed you a payload directory,
skip to step 3.

## 1. Find out what you have

```
installer\build\aowlspt-install.exe detect
```

```
D:\Games\Tarkov
---------------
  root      D:\Games\Tarkov
  version   1.1.0.46777
  manifest  1.1.0.1.46777  (ConsistencyInfo)
  backend   IL2CPP
  flavour   vanilla
  build     027f6efbac104c93993ac42b36d26826
  present   BattlEye
  suitable  yes — this is a post-1.0 client
```

Write the **version** down. It is the number the payload has to declare, and it
is read out of the executable's version resource — the one thing in the
directory that cannot be made to lie by copying a file in next to it.

`detect` searches the usual places. If your install lives somewhere unusual,
pass the path: `aowlspt-install detect E:\Tarkov`.

## 2. Build the payload

```
installer\build\aowl.exe build
installer\build\aowl.exe payload
```

`build` compiles the hosts, the backend, the launcher, the tools and every mod.
`payload` collects the results into `installer\payload\aowlspt\`:

```
installer\payload\
  payload.json               what this was built for; edit it, see below
  registry\mods.json         every mod that exists, and the lists that name them
  aowlspt\
    aowlspt-host-il2cpp.dll  the host that goes into the client
    aowlspt-launch.exe       what starts the game with the host inside it
    aowlspt-backend.exe      the server
    aowlspt-host.json        how long the host waits for IL2CPP to come up
    mods\<name>\<name>.dll   every mod, with its config.json and its data\
```

`payload.json` is **not** produced by `aowl payload` and is not in the
repository: it is per-machine, so it is `.gitignore`d and you make it once.

```
copy installer\payload\payload.json.template installer\payload\payload.json
```

Then open it and make `targetTarkovVersion` the number `detect` gave you.
`aowl payload` ends with a warning when the file is still missing; that warning
is this paragraph.

```json
{
  "name": "aowlspt",
  "version": "0.1.0",
  "targetTarkovVersion": "1.1.0.46777",
  "targetBackend": "il2cpp",
  "kind": "full",
  "backendUrl": "https://127.0.0.1:6969"
}
```

Every key here is load-bearing and three of them are checked before anything is
written:

| key | what it decides |
|---|---|
| `targetTarkovVersion` | whether these binaries match the client in front of you |
| `targetBackend` | `il2cpp` for post-1.0, `mono` for pre-1.0. Not inferable from the version |
| `kind` | `full` mirrors a client from `--source` into `--target` and lays the payload over it. `overlay` adds only to an install already at `--target` |

**Read the exit codes, not just the output.** `aowl build` exits 1 if any one
mod fails to compile. `aowl payload` used to exit **0** anyway, staging that
mod's `config.json` and `data/` into a directory with no library in it —
which installs perfectly, is loaded by nothing, and says nothing at all until
step 6. It now refuses:

```
error mod <name> has no library; its config and data would install as a
      directory nothing loads. Build it first.
error 1 mod(s) staged without a library; this payload is not installable
```

**The three binaries a payload is useless without are refused on the same
terms.** A missing IL2CPP client host means the install you are about to make
starts the game with no mods in it; a missing backend means the client has
nothing to talk to; a missing launcher means there is no way to start the game
at all. Each of the three used to be a *warning* on a run that exited 0 —
`aowl release` and `aowlspt-verify` both caught it later, so the release path
was safe, but a payload staged by hand and installed straight was not. All
three are now errors (`tools/aowl.nim:1891`, `:1903`, `:1913` — re-derived
2026-08-19; this said `:1721`, `:1733`, `:1743`, which by then had drifted about
170 lines and landed on the store-crash gate and two blank lines) and they are
counted into the same tally as a library-less mod:

```
error the IL2CPP client host is not built; a post-1.0 payload without it
      installs a client that loads nothing. Build it first.
error 1 missing piece(s) above; this payload is not installable
```

What `aowl payload` still only *warns* about is a missing
`registry/mods.json` — the mod manager would have nothing to manage — and a
missing `payload.json`, which is the paragraph above. **Read the warnings.**

## 3. See what would happen

```
installer\build\aowlspt-install.exe plan ^
    --source D:\Games\Tarkov ^
    --target D:\Aowlspt ^
    --payload installer\payload
```

`plan` prints the client it found, the payload it loaded, the registry it will
install, every objection it has, and then the list of steps — and does nothing
at all. That list is not an approximation of what `install` does; it is the same
list, executed.

`--source` is the install your launcher maintains. It is opened read-only and
never written to. `--target` is a new directory beside it — not inside it, and
not inside the source; the installer refuses both.

## 4. Install

```
installer\build\aowlspt-install.exe install ^
    --source D:\Games\Tarkov ^
    --target D:\Aowlspt ^
    --payload installer\payload
```

It prints the same plan, asks once, and does it. `--yes` skips the question,
which is what a script wants and not what you want the first time.

On a real install this takes seconds, because the ~77 GB of asset bundles that
nothing ever writes to are hard linked rather than copied. Everything a patcher
could plausibly rewrite —
the executables, `GameAssembly.dll`, `UnityPlayer.dll`, `il2cpp_data\`,
`Plugins\`, `boot.config` — is copied even so, because a hard link is a second
name for the same bytes and writing through one would reach back into the
install you are trying to protect. `--copy` turns linking off entirely if you
would rather have the second copy.

What lands in `D:\Aowlspt`:

```
D:\Aowlspt\
  EscapeFromTarkov.exe          copied
  EscapeFromTarkov_Data\        mostly hard linked
  aowlspt\                      everything this project owns
    aowlspt-launch.exe
    aowlspt-backend.exe
    aowlspt-host-il2cpp.dll
    backend.json                where the client looks for the backend
    mods\
    registry\mods.json
  aowlspt-install.txt           what was created, for uninstall
```

`BattlEye` and `ConsistencyInfo` are not carried across. BattlEye is anti-cheat
for the live service that this client never talks to; `ConsistencyInfo` is BSG's
file manifest, which a modified install fails by definition.

Useful flags:

- `--list ID` — the mod list a fresh install starts with. The default is
  `aowl.list.vanillaplus`: the game server plus the three mods that change how
  the game feels without changing what is in it. `--list aowl.list.raidnight`
  turns the bots up; `--list none` leaves the mod manager's own default alone.
- `--overlay` — do not mirror a client; only (re)write the payload into a target
  that already has one. What you want when you have rebuilt the mods and do not
  want to re-link forty thousand files.
- `--registry PATH` — install a `mods.json` from somewhere other than the
  payload.
- `--dry-run` — print every step and execute none.

## 5. Give it the game's data

**This step is not optional and it is not in the installer.** Everything above
produces a complete, verifiable, *empty* server: it answers every route the
client asks, out of the emulator's built-in fallbacks, with no items, no
traders, no quests and no maps in any of them. The payload does not carry a
database and cannot — what would be in it is BSG's data, by way of SPT's, and
that is not something this repository distributes.

```
installer\build\aowl.exe importdb --from D:\SPT --out D:\Aowlspt\aowlspt
```

From the archive the same importer is a tool of its own, because this step is
mandatory and there is no `aowl.exe` in a download:

```
install\aowl-importdb.exe --from D:\SPT --out D:\Aowlspt\aowlspt
```

About three seconds and 39 MiB later there is a `db.json` where the backend looks
for it. **`--out` is the `aowlspt\` directory inside the install, not the
install root**: the backend is started with `--root <target>\aowlspt` and
reads `<root>\db.json`. Put it one level up and the server comes up on its
fallbacks with nothing anywhere saying why.

The importer opens the SPT install read-only and refuses an `--out` inside it.
[IMPORTDB.md](IMPORTDB.md) has what converts, what does not, what the self-check
asserts, and the flags for a smaller or larger database.

If you do not have an SPT install, you do not have a database, and there is
currently no other way to get one. The server will still start, `aowlspt-verify`
will still pass, and the game will have nothing in it.

## 6. Check it

```
installer\build\aowlspt-verify.exe --root D:\Aowlspt
```

This is the one worth running. It checks the client is post-1.0 and IL2CPP, that
the host, launcher and backend are all there, that **every mod directory
actually holds a library** and not just a config nobody reads, that the registry
went in and the default list is one the registry defines — and then it starts
the backend on a spare port, asks it the first four questions the client asks,
and stops it again.

```
Result
------
  36 checks
  0 warning(s)
ok    this install is complete and serves
```

The count moves as mods are added, so do not read a number off this page; read
the failures and the warnings. (36 with 0 warnings is what a `tools/firstrun.nim
--keep` install answered on the development machine on 2026-08-19. This page
showed **28 checks and 1 warning**, and 28 turns out to be the count
`--offline` gives on the *same* install — the offline run really does answer
"28 checks" today. So the sample was the narrower run's tally under the wider
run's last line. It was 26 when this page was first written, and the number
moving is the point.)

**The warnings are the interesting part.** A missing `db.json` is one of them:
the install is not broken, there is no game in it, and those are two different
sentences.

```
warn  the game's data is installed: there is no D:\Aowlspt\aowlspt\db.json,
      so the emulator answers out of its own fallbacks: it will serve, and the
      client will find no items, no traders and no quests.
```

A `db.json` under about 4 MB gets its own warning, because a real import is
tens of megabytes and anything smaller is a test fixture or a half-written
file. So does an install whose `aowlspt-install.txt` does not name a release,
which means it was assembled by hand out of a staging directory rather than
installed from a payload.

The last line is exact about what was proved. "this install is complete and
serves" is printed only when the backend was started and answered; with
`--offline`, which starts nothing, it prints "the files of this install are all
present" and says what it did not do. A tool that reports a server answering
when it never opened a socket is the failure it exists to catch.

Without `--offline` it takes **about three seconds** on an install with a real
database — 2.6 s measured 2026-08-19 — almost all of it waiting for the backend
to load. This page said "about a minute", which was true while the backend took
54 s to come up and stopped being true when the mods stopped issuing 420
`dbPatch` calls between them. Step 7 has that story, and used to be what this
sentence pointed at as the excuse; it is now the reason there is nothing to
excuse.

`aowlspt-install verify --target D:\Aowlspt` is a different and narrower check:
it reads the uninstall manifest and asks whether the paths it names are still
there. Both are worth having.

## 7. Play

```
D:\Aowlspt\aowlspt\aowlspt-launch.exe
```

It starts the backend, checks a moment later that it has not exited, then
starts `EscapeFromTarkov.exe` **suspended**, loads `aowlspt-host-il2cpp.dll` into it,
and resumes. The game comes up with the host already inside it and nothing in
the install pretending to be a Windows component — no `winhttp.dll`, no
doorstop, no BepInEx.

- `--dry-run` reports what it would start and starts nothing.
- `--wait` keeps the launcher open until the game exits and stops the backend
  after it.
- `--no-backend` starts the client alone, for when you are already running a
  backend elsewhere.

Two logs, and between them they answer almost every question:

| file | what it holds |
|---|---|
| `D:\Aowlspt\aowlspt\aowlspt-host.log` | the client host: which mods loaded, what it could resolve in IL2CPP |
| `D:\Aowlspt\aowlspt\aowlspt-backend.log` | the server: which mods loaded, which routes exist, what the mod manager resolved |

On a cold launch the host waits for the game to bring IL2CPP up before it can
resolve anything, which takes a while. `aowlspt-host.json` sets how long.

**The server is the slow half, and the launcher now waits for it.** Measured on
the development machine, with the mod set a default install carries and the
39 MiB imported database:

| | boot to first answer |
|---|---:|
| the emulator alone, imported database | 0.6 s |
| every mod in the payload, imported database | **2.9 s** |
| the same, before the mods were batched | 54 s |

The 54 s was one defect wearing four hats, and it was never really the mods.
`dbWrite` costs the size of the *database*, not the size of the patch: the
backend holds the whole thing as one text document, splices the patch into it,
and throws its member index away — so every call copies 41 MB twice and the next
read rebuilds the index by scanning 41 MB again. That is **95–130 ms per call**,
whatever the call says.

Four mods were issuing about **420** of them between them. `blackdivision`
registering through `morebots` was ~390 on its own, mostly hostility relations:
`fromFaction: "savage"` names thirty-seven roles and each one had four `Mind`
arrays read and written individually. `sain` wrote one map at a time (19),
`icebreaker` one table at a time (13). Each mod now builds its whole
contribution in memory and writes it in as few patches as its shape allows —
ten between all four — and the resulting document is identical, because a merge
of merges is the same document as one merge of the merged patch.

What is left is those ten calls, about 1.9 s of the 2.9. Going lower means
making `dbPatch` itself cheaper than "rewrite the document"; the mods have run
out of writes to remove.

`aowlspt-launch` no longer sleeps a fixed 1.2 s before starting the client. It
polls `127.0.0.1:<port>` until the backend answers a request — a socket that
accepts is exact rather than approximate, because the backend opens the port
only after the last mod has loaded — printing a line every five seconds while it
waits, and giving up after `--backend-wait` seconds (300 by default) with a
warning rather than silently. So the old workaround is no longer needed; it
still works if you want the server in its own window:

```
D:\Aowlspt\aowlspt\aowlspt-backend.exe --root D:\Aowlspt\aowlspt --port 6969
D:\Aowlspt\aowlspt\aowlspt-launch.exe --no-backend
```

With `--no-backend` the launcher checks the port once and says whether anything
is answering, rather than assuming.

**Stopping the server is killing it.** There is no shutdown route and no console
handler; `--wait` stops the backend with `TerminateProcess` when the game exits,
and closing the window does the same. That is safe on purpose rather than by
luck — a profile write is a temporary file renamed over the key, so there is no
half-written value to find afterwards (`docs/BACKEND.md`, "What survives a
crash") — but it does mean "stop the server" and "kill the server" are the same
operation here.

If the launcher cannot inject, it **kills the client rather than resuming it**.
A game running without its host is worse than no game, because you would be in a
raid before noticing.

## Managing mods

While the backend is running, the mod manager answers over the same HTTP the
client uses:

```
installer\build\aowlprobe.exe http://127.0.0.1:6969/aowlspt/mods
installer\build\aowlprobe.exe http://127.0.0.1:6969/aowlspt/mods/lists
installer\build\aowlprobe.exe http://127.0.0.1:6969/aowlspt/mods/enable/aowl.sain
```

Plain `curl` will not do: bodies are zlib-framed in both directions, which is
why `aowlprobe` exists. See [registry/README.md](../registry/README.md) for the
lists and the resolution rules, and press **Insert** in game for the overlay.

Your own choices live in the mod manager's store, not in the registry and not in
`config.json`. The `--list` you installed with is the seed for the first run and
is not consulted again after you change anything.

`disable` and `enable` record a decision; **`/aowlspt/mods/apply` is what
performs it.** The reply to a disable says so (`"inEffect":"apply it with
/aowlspt/mods/apply"`), and a route belonging to a disabled mod keeps answering
until you call it.

**A `"not-selected"` mod is not running.** This page used to say the opposite —
that the backend loaded every `.dll` under `aowlspt\mods\` and nothing took the
unselected ones out until somebody called `/aowlspt/mods/apply`, so a mod the
panel reported as `"not-selected"` had already run its `on_load` and registered
its routes. That is no longer true. The manager writes what it resolved to
`aowlspt-selection.json`, and `modhost.loadAll`
(`host/common/modhost.nim:862`) reads that file through `readSelection`
(`:599-686`) *before* it opens anything: each candidate library is loaded, asked
what it calls itself through `describe`, and put straight back down without
being initialised (`probeGuid`, `:688-726`). A mod that is not in `load` never
runs a line of its own code — no `on_load`, no database writes, no routes.
(Re-derived 2026-08-19. This cited `:646-717` and `probeGuid` at `:657`; both
had drifted, and `:657` had come to sit inside `readSelection`'s body.)

Four ways of not having a selection and all four load everything, which is what
a fresh install needs: the file absent, unreadable, written for another side, or
naming an empty `load`. [MODMANAGER.md](MODMANAGER.md) has why the last one is a
refusal rather than an instruction. A brand-new install has no selection file
until the manager has run once, so the first start after installing is still a
directory walk.

## Refusals

Every refusal names the fact it is refusing on. Two of them cannot be
overridden.

### "this payload would downgrade you across 1.0" — not overridable

Your client is 1.x and the payload was built for a 0.x one. The usual way to get
a modded Tarkov running is to roll the client back to whatever older build the
mod runtime was written against; getting from 1.1 to 0.16 is not a patch, it
replaces the client's assemblies and asset bundles with an older game's, and it
means the game you play is not the game you own. `--force` does not enable it,
by design.

**What to do:** get a payload built for your client, or build one — step 2, with
`targetTarkovVersion` set to what `detect` reports.

### "scripting backend mismatch" — not overridable

The payload declares `mono` and the client is IL2CPP, or the reverse. A Mono
BepInEx plugin has no way to load into an IL2CPP process and an IL2CPP interop
assembly has nothing to bind to under Mono. No version flag settles that.

**What to do:** fix `targetBackend` in `payload.json` if it is simply wrong;
otherwise you have a payload for a different game.

### "client version unreadable" / "client layout unrecognised" / "not a Tarkov install"

`--source` does not point at a complete install, or `EscapeFromTarkov.exe` has
no version resource. A client that cannot be identified is not one to install
over.

**What to do:** point `--source` at the folder holding `EscapeFromTarkov.exe`.
If it is a partial download, let the official launcher finish.

### "payload is older / newer than the client" — `--force` clears it

The numbers do not match. Older usually loads and sometimes misbehaves; newer
means update the game and try again.

**What to do:** update the game, or rebuild the payload, or pass `--force` if
you know this pair works.

### "the source is already an SPT install" — `--force` clears it

`SPT_Runtime` is present in `--source`. `--source` is meant to be the untouched
install the launcher maintains, so the target can be thrown away and rebuilt at
any time. Installing from an already-patched copy carries its patches forward
invisibly.

**What to do:** point `--source` at the vanilla install. SPT is pre-1.0 anyway,
so a post-1.0 payload will refuse it at the next check regardless.

### "this registry defines no list called ..." — `--force` clears it

`--list` names a list `mods.json` does not have. A default naming a list that
does not exist resolves to nothing, and you would get an install with every mod
off and no reason given anywhere.

**What to do:** `--list none`, or one the registry defines — `plan` prints how
many lists it found, and `registry/mods.json` names them.

### "no aowlspt install manifest in ..." (uninstall)

`aowlspt-install.txt` is missing. Nothing is removed without it; guessing at
what to delete in a game directory is not a thing this program does.

**What to do:** if it was a full install, the target is entirely this
installer's and deleting the directory is the same operation.

## Uninstalling

```
installer\build\aowlspt-install.exe uninstall --target D:\Aowlspt
```

It removes exactly the paths `aowlspt-install.txt` names, and nothing else. For
a **full** install that is the target directory, including its copy of the
client; for an **overlay** it is only what was added, and the install underneath
is left as it was. The source is not touched in either case.

## What has actually been tested

Being specific about this, because "it works" is doing a lot of work in most
install guides.

| | |
|---|---|
| the installer's refusal matrix | 126 automated checks, against constructed values — including the cases you cannot produce on demand |
| the filesystem layer | against a real temporary directory, including that a hard-linked file in the target does not write through to the source |
| build → payload → install → verify → launch | end to end, against a synthetic install carrying a real version resource, IL2CPP layout and asset bundles |
| the whole first-run path, in this order | `tools/firstrun.nim`: from a synthesised vanilla client through payload, install, `importdb`, `verify`, the client's boot sequence against a 39 MiB imported database, a mod switched off and on live, and a restart with the profile still in it |
| the release archive | `aowl release`: every gate before a byte is written, then the `.zip` it just wrote opened again and checked entry by entry against the shape the installer reads. Two runs of one tree into one output directory are byte-identical |
| the host inside a foreign process | injected, loaded its mods, and reported the IL2CPP runtime as absent rather than crashing — which is the correct answer when there is no game |
| the backend and the emulator | started from the installed tree and answered the client's boot sequence over the wire, zlib framing included |
| **the real client** | **never** |

The gap in the last row is the whole gap. Everything above it says the pipeline
is sound; none of it says the game starts.
