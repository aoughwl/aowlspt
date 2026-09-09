# aowlspt-install

Turns the Tarkov install your official launcher maintains into an aowlspt
install, without touching the one your launcher maintains.

Written in nimony, like everything else here. It has no dependencies beyond
Win32 — no .NET, no PowerShell, no runtime to install before you can install.

```
aowlspt-install detect
aowlspt-install plan      --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
aowlspt-install install   --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
aowlspt-install verify    --target D:\Aowlspt
aowlspt-install uninstall --target D:\Aowlspt
```

For the whole path from a vanilla install to a running game -- what each of
these does, in order, and what every refusal means -- see
[docs/INSTALL.md](../docs/INSTALL.md).

## Start here

```
> aowlspt-install detect

Tarkov installs found on this machine
-------------------------------------

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

Three facts, from three independent places. The **version** is the resource
BSG stamps into `EscapeFromTarkov.exe`, which is the only one that cannot be
made to lie by copying a file in next to it. The **backend** is Mono or IL2CPP,
read from the shape of `EscapeFromTarkov_Data`, and is not derivable from the
version. The **flavour** is whether something has already been installed over
the top.

## Two properties worth knowing about

**The source is only ever read.** Everything is built in a separate `--target`.
The install your launcher maintains stays canonical and stays updatable, and
you can throw the target away and rebuild it at any time without
re-downloading 78 GB. This is why `install` takes a `--target` at all instead
of patching in place, which is the usual design and the one that costs people
a re-download when it goes wrong.

**It refuses more readily than it proceeds.** Every refusal names the fact it
is refusing on. Two of them cannot be overridden:

- **A payload that would take a post-1.0 client backwards across 1.0.** The
  usual way to get a modded Tarkov running is to roll your client back to
  whichever older build the mod runtime was written against. That is not a
  patch — it replaces the client's assemblies and asset bundles with an older
  game's — and it means the game you play is not the game you own. `--force`
  does not enable it.
- **A scripting-backend mismatch.** A Mono BepInEx plugin has no way to load
  into an IL2CPP process. No flag settles that.

Everything else — a payload built for a neighbouring build of the same
release, a source that already has a mod loader in it — is a *block*, which
`--force` clears once you have read what it says.

## How a full install is laid down

```
mirror  D:\Games\Tarkov  ->  D:\Aowlspt   (without BattlEye, ConsistencyInfo, ...)
copy    payload\aowlspt  ->  D:\Aowlspt\aowlspt
copy    payload\aowlspt\registry\mods.json  ->  D:\Aowlspt\aowlspt\registry\mods.json
write   D:\Aowlspt\aowlspt\mods\manager\config.json   (the default mod list)
write   D:\Aowlspt\aowlspt\backend.json
```

That list is printed before anything happens, and `plan` prints it without
doing anything at all. It is not an approximation of what `install` does — it
is the same list, executed, in the order it is printed.

Every step after the mirror is conditional on the payload actually carrying that
part, which is how the same program lays down a full install and an
overlay-only one without a second code path. A payload `aowl payload` produces
carries only `aowlspt/`, so those are the steps you will see; the installer also
still honours `payload\runtime` and `payload\client` if a payload has them, and
skips each silently when it does not. `backend.json` is written only when the
payload names a `backendUrl`.

### Mirroring, and the sharp edge in it

A Tarkov install is ~78 GB, of which ~77 GB is asset bundles that nothing ever
writes to. Those are **hard linked** rather than copied, so a full install
takes seconds and no additional disk.

A hard link is not a copy. It is a second name for the same bytes, so anything
that opens the target file for writing writes into the source install too. The
installer is careful about this in its own writes — every write replaces the
destination rather than opening it — but it cannot be careful on behalf of
every tool that touches the install afterwards.

So everything a mod loader or patcher could plausibly rewrite is copied even
when the rest is linked — the `hot` list in `installer/src/aowlsptinstall.nim`:
`EscapeFromTarkov.exe`, `UnityPlayer.dll`, `GameAssembly.dll`, `baselib.dll`,
`UnityCrashHandler64.exe`, and under `EscapeFromTarkov_Data/`: `Managed/`,
`il2cpp_data/`, `Plugins/`, `Resources/`, `globalgamemanagers` and
`boot.config`.
A few hundred megabytes out of 78 GB, which buys back nearly all of the speed
and none of the risk. `--copy` turns linking off entirely.

`BattlEye` and `ConsistencyInfo` are not carried across at all. BattlEye is
anti-cheat for the live service, which the modded client never talks to;
`ConsistencyInfo` is BSG's file manifest, which a modified install fails by
definition.

## Uninstalling

`install` writes `<target>\aowlspt-install.txt`: plain text, one path per line,
listing exactly what was created. `uninstall` removes those paths and nothing
else, and refuses to run without the file — guessing at what to delete in a
game directory is not something this program does.

The manifest records which kind of install it was, because it changes what
uninstall means:

- **full** — the target holds its own copy of the client, and removing it
  removes that copy. The source is unaffected.
- **overlay** — only `<target>\aowlspt\` was added, and only that is removed.

## The registry, and what an install starts with

An install that stops at the binaries is one where `mods/manager` comes up
reporting *"no registry found. Looked at: ..."* and manages nothing -- on an
install that is otherwise complete. So two more things go in.

**The registry** (`registry/mods.json`: every mod that exists, and every named
list of them) is copied to `<target>/aowlspt/registry/mods.json`, which is one
of the places the manager searches, and is inside the one directory this
installer owns and can therefore remove again. It comes out of the payload --
`payload/aowlspt/registry/mods.json` first, then `payload/registry/mods.json`
-- or from `--registry PATH`, which may name the file or the directory holding
it. A `--registry` that names nothing does *not* fall back to the payload's:
installing a registry other than the one you asked for is how somebody spends an
evening debugging a mod list they are not running.

**The default selection** is `--list ID`, defaulting to `aowl.list.vanillaplus`.
The manager seeds its stored selection from `activeLists` in its own
`config.json`, once, on first run; there is no other seeding path. So this is
done by *patching the payload's copy of that config* -- one value replaced, the
rest of the document left exactly as the mod author wrote it. A config written
from a template here would be missing every setting the mod grows after today,
and the mod would silently fall back to defaults for all of them. If the key is
not there in the shape expected, nothing is changed and the installer says so,
rather than appending a second `activeLists` that would win or lose depending on
which one the parser reaches last.

`--list none` installs the registry and leaves the payload's own default alone.
A `--list` naming a list the registry does not define is a *block*: it would
resolve to nothing, and you would get an install with every mod off and no
reason given anywhere.

## Payloads

See [payload/README.md](payload/README.md). Short version: a payload is a
directory with a `payload.json` declaring which Tarkov client and which
scripting backend its binaries were built for, and whether installing it
mirrors a client or only adds to one. The installer will not install one that
does not say.

That last part -- `"kind": "full"` or `"overlay"` -- is declared rather than
inferred, and it was not always. The inference was "it carries a `runtime/` or a
`client/`, so it builds a whole install", which was right for pre-1.0 Tarkov,
where a playable install meant BepInEx and doorstop and SPT's server. A post-1.0
payload has neither: the host is injected at start-up and the server is one of
the mods, so everything it ships lives in `aowlspt/`. Left to the inference,
that payload read as an overlay -- and an overlay never mirrors the client, so
`install --source <vanilla> --target <new>` produced a target holding `aowlspt/`
and no game at all, and reported success.

`--overlay` on the command line forces the overlay path for a payload that
declares `full`, which is what you want when you have rebuilt the mods and would
rather not re-link forty thousand asset bundles. It can only ever turn the
mirroring *off*: a payload with no client in it cannot be talked into producing
one.

## Building and testing

```
nimony c -p:src -o:build/aowlspt-install.exe src/aowlsptinstall.nim
nimony c -p:src -o:build/test-installer.exe tests/test_installer.nim
build/test-installer.exe
```

The tests are worth a word. The refusal matrix is tested against constructed
values rather than real installs, because the cases that matter are the ones
you cannot produce on demand: a client reporting no version, an IL2CPP payload
aimed at a Mono client, a pre-1.0 payload aimed at a post-1.0 one. The
filesystem layer is tested against a real temporary directory, because the
whole reason it exists is that Win32 behaves in ways a mock would not.

One of those filesystem tests earns its keep already: it caught `writeTextFile`
opening its destination instead of replacing it, which meant writing a config
into a mirrored install wrote *through the hard link into the vanilla game*.
That is the failure this program exists to prevent, and it was in the program.

## Layout

```
src/aowlsptinstall.nim        the CLI
src/aowlsptinstall/winfs.nim  copy, hard link, recursive walk and remove
src/aowlsptinstall/eft.nim    identifying an install: version, backend, flavour
src/aowlsptinstall/payload.nim  what is being installed, and what it claims
src/aowlsptinstall/compat.nim   whether it may be, and why not
src/aowlsptinstall/plan.nim     the steps, as data; and applying them
src/aowlsptinstall/registry.nim  the mod registry, and the default selection
src/aowlsptinstall/journal.nim  the uninstall manifest
src/aowlsptinstall/log.nim      output
tests/test_installer.nim      all of the above
```
