# Payloads

A **payload** is what `aowlspt-install` installs. It is a directory, not an
archive and not a download URL, and it carries a manifest saying which Tarkov
client its contents were built against.

```
payload/
  payload.json        required
  runtime/            copied over <target>/    the backend server and its data
  client/             copied over <target>/    the mod loader the client boots through
  aowlspt/            copied to <target>/aowlspt/    hosts and mods
  registry/mods.json  copied to <target>/aowlspt/registry/mods.json
```

Every directory is optional. `kind` in the manifest decides what kind of install
you get:

| kind | what happens |
|---|---|
| **full** | the client is mirrored from `--source` into `--target`, then the payload goes over it |
| **overlay** | nothing is mirrored; the payload is added to the install already at `--target` |

The difference matters at uninstall time. A full install owns its target, so
removing it removes the target. An overlay owns only what it added, so removing
it leaves the install it was added to exactly as it was.

### Why `kind` is declared and not inferred

It used to be inferred: a payload carrying `runtime/` or `client/` built a whole
install, one carrying only `aowlspt/` was an overlay. That was right for pre-1.0
Tarkov, where a playable install meant BepInEx and doorstop in `client/` and
SPT's server in `runtime/`.

A post-1.0 payload has neither, and this repository produces no other kind. The
host is injected into the client at start-up by `aowlspt-launch` and the server
is one of the mods, so everything ships in `aowlspt/`. Left to the inference,
the payload this repository builds read as an *overlay* -- and an overlay never
mirrors the client. So

```
aowlspt-install install --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
```

produced `D:\Aowlspt\aowlspt\` holding the hosts and the mods, no game beside
them, and a cheerful "installed into D:\Aowlspt". That is the whole first-run
path failing quietly, which is why the manifest gets to say.

A payload declaring a `kind` that is neither word is rejected rather than
guessed at. `--overlay` on the command line forces the overlay path for a
payload that declares `full` -- what you want when you have rebuilt the mods and
would rather not re-link forty thousand asset bundles. It can only ever turn
mirroring off: a payload with no client in it cannot be talked into producing
one.

### What a payload deliberately does not carry

There is no `db.json` in a payload and there will not be one. The emulator's
database is BSG's data by way of SPT's; it is produced locally, from an install
the person already owns, by `aowl importdb`, and it is neither committed here
nor shipped in a release. So an install made from a payload is complete and
serves and has nothing in it until that command has been run:

```
aowl importdb --from D:\SPT --out <target>\aowlspt
```

From a release archive there is no `aowl.exe`; the importer ships as a tool of
its own beside the installer, and takes the same flags:

```
install\aowl-importdb.exe --from D:\SPT --out <target>\aowlspt
```

`--out` is the `aowlspt\` directory, not the target root: the backend runs with
`--root <target>\aowlspt` and reads `<root>\db.json`. Put it one level up and
the server comes up on its fallbacks with nothing anywhere saying why.
`aowlspt-verify` warns when there is no `db.json` and warns again when there is
one too small to be a real import — it does not fail, because an install
without a database is not broken, it is empty. INSTALL.md step 5 has this in
its place in the order (`docs/INSTALL.md` in the repository, `INSTALL.md` beside
this file in a release archive), and `tools/firstrun.nim` walks the whole order
and asserts it.

## The registry

`registry/mods.json` is the mod registry: every mod that exists, and every named
list of them (see [registry/README.md](../../registry/README.md)). It is
installed to `<target>/aowlspt/registry/mods.json`, which is one of the places
`mods/manager` searches.

A payload without one installs perfectly well, and then the mod manager comes up
reporting *"no registry found. Looked at: ..."* and managing nothing -- on an
install that is otherwise complete, in a log nobody reads until something is
wrong. So `aowlspt-install` says so before it writes anything, and
`aowlspt-verify` says so afterwards.

It may also live at `aowlspt/registry/mods.json` inside the payload, which is
where a build tool staging it into the `aowlspt/` tree would naturally put it;
that location wins when both exist. `--registry PATH` overrides both, and does
not fall back when the path it names holds nothing.

## payload.json

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

| key | required | meaning |
|---|---|---|
| `name` | yes | shown during install, recorded in the manifest |
| `version` | no | the payload's own version |
| `targetTarkovVersion` | **yes** | the client these binaries were built against |
| `targetBackend` | **yes** | `mono` or `il2cpp` |
| `kind` | no | `full` or `overlay`. Inferred from `runtime/`/`client/` when absent, which is wrong for every post-1.0 payload -- see above |
| `backendUrl` | no | written to `<target>/aowlspt/backend.json` |

`targetTarkovVersion` and `targetBackend` are required and the installer will
not proceed without them. They are the entire basis on which it decides whether
your binaries can run on the client in front of it, and a payload that declines
to say what it was built for is one whose failures land on the person who
installed it rather than on the person who packaged it.

Read the number off the client with:

```
aowlspt-install detect D:\Games\Tarkov
```

## Why the installer does not download anything

It installs from a directory you assembled, which means:

- the thing deciding "is this safe on that client" reads a declaration rather
  than guessing;
- a payload built for a newer Tarkov drops in without changing the installer;
- the installer is never the component that acquires game files.

## What `aowl payload` puts in `aowlspt/`

```
aowlspt/
  aowlspt-host-il2cpp.dll   the post-1.0 client host
  aowlspt-launch.exe        starts the game with that host inside it
  aowlspt-host.json         how long the host waits for IL2CPP to come up
  aowlspt-backend.exe       the server
  mods/<name>/<name>.dll    every built mod, with its data/ and config.json
```

A mod's `config.json` and `data/` go beside its library, and that is not a
nicety: some mods *are* their data -- a faction is bot templates, loadouts and
locale -- so a payload carrying the library without them installs a mod that
loads and does nothing.

The converse is worth watching for too. `aowl payload` stages a mod's config and
data whether or not the library beside them got built, so a mod whose build
failed would install as a directory full of settings that nothing reads -- and
the host, which loads by scanning for `.dll`, says nothing at all about it.
That is now refused in three places rather than one, because it was found by
happening: `aowl payload` exits non-zero and names the mod, `aowl release`
refuses to package the payload, and `aowlspt-verify` fails the finished
install.

This repo only builds `il2cpp` payloads. The client host is
`aowlspt-host-il2cpp.dll`, loaded into the post-1.0 client by `aowlspt-launch`
with no BepInEx involved at all — see [docs/IL2CPP.md](../../docs/IL2CPP.md).
There is no longer a `client/` or a `server/` directory: the Mono BepInEx plugin
and the SPT 4.x server host were deleted with the pivot to post-1.0, because a
Mono plugin cannot load into an IL2CPP process and the server half is now
`aowlspt-backend`.

`targetBackend` is still declared, and the installer still refuses a `mono`
payload on an IL2CPP client and the reverse. That check is about the client in
front of it, not about what this repo happens to produce: neither kind of
binary loads into the other, and no version flag changes that, which is why the
backend is declared rather than inferred.

The server side does not care either way: it is an HTTP backend and is
indifferent to the client's scripting backend. A payload with `runtime/` and
`aowlspt/` and no client host at all is a perfectly good thing to install.

The installer reports precisely which of these you have, before it writes
anything.
