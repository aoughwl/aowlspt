# Installing

From a Tarkov install the official launcher maintains, to a modded one you can
start. Six commands, in order, and what to do when one of them refuses.

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
  suitable  yes -- this is a post-1.0 client
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

Then open `installer\payload\payload.json` and make `targetTarkovVersion` the
number `detect` gave you:

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

`aowl payload` warns if a piece is missing rather than staging a payload that
looks complete. **Read those warnings.** "the IL2CPP client host is not built"
means the install you are about to make will start the game with no mods in it.

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

It prints the same plan, asks once, and does it. On a real install this takes
seconds, because the ~77 GB of asset bundles that nothing ever writes to are
hard linked rather than copied. Everything a patcher could plausibly rewrite —
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

## 5. Check it

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
  29 checks
ok    this install is complete and serves
```

`--offline` does the file checks and starts nothing.

`aowlspt-install verify --target D:\Aowlspt` is a different and narrower check:
it reads the uninstall manifest and asks whether the paths it names are still
there. Both are worth having.

## 6. Play

```
D:\Aowlspt\aowlspt\aowlspt-launch.exe
```

It starts the backend, waits until it is actually up, then starts
`EscapeFromTarkov.exe` **suspended**, loads `aowlspt-host-il2cpp.dll` into it,
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
| the installer's refusal matrix | 122 automated checks, against constructed values — including the cases you cannot produce on demand |
| the filesystem layer | against a real temporary directory, including that a hard-linked file in the target does not write through to the source |
| build → payload → install → verify → launch | end to end, against a synthetic install carrying a real version resource, IL2CPP layout and asset bundles |
| the host inside a foreign process | injected, loaded its mods, and reported the IL2CPP runtime as absent rather than crashing — which is the correct answer when there is no game |
| the backend and the emulator | started from the installed tree and answered the client's boot sequence over the wire, zlib framing included |
| **the real client** | **never** |

The gap in the last row is the whole gap. Everything above it says the pipeline
is sound; none of it says the game starts.
