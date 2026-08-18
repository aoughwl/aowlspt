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
```

All three directories are optional. What you include decides what kind of
install you get:

| contains | kind | what happens |
|---|---|---|
| `runtime/` and/or `client/` | **full** | the client is mirrored from `--source` into `--target`, then the payload goes over it |
| `aowlspt/` only | **overlay** | nothing is mirrored; the payload is added to the install already at `--target` |

The difference matters at uninstall time. A full install owns its target, so
removing it removes the target. An overlay owns only what it added, so removing
it leaves the install it was added to exactly as it was.

## payload.json

```json
{
  "name": "aowlspt",
  "version": "0.1.0",
  "targetTarkovVersion": "1.1.0.46777",
  "targetBackend": "il2cpp",
  "backendUrl": "https://127.0.0.1:6969"
}
```

| key | required | meaning |
|---|---|---|
| `name` | yes | shown during install, recorded in the manifest |
| `version` | no | the payload's own version |
| `targetTarkovVersion` | **yes** | the client these binaries were built against |
| `targetBackend` | **yes** | `mono` or `il2cpp` |
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
  mods/<name>/<name>.dll    every built example mod
  server/                   the .NET server host, for SPT's server
  client/                   the Mono BepInEx plugin, for pre-1.0 clients
```

`targetBackend` decides which of the two client hosts is the relevant one.
`il2cpp` means the post-1.0 client, hosted by `aowlspt-host-il2cpp.dll` with no
BepInEx involved at all — see [docs/IL2CPP.md](../../docs/IL2CPP.md). `mono`
means a pre-1.0 client, where `client/` is the BepInEx plugin and `aowlspt/`
is deployed under `BepInEx/plugins`.

Neither loads into the other, and no version flag changes that, which is why
the backend is declared rather than inferred.

The server side does not care either way: it is an HTTP backend and is
indifferent to the client's scripting backend. A payload with `runtime/` and
`aowlspt/` and no client host at all is a perfectly good thing to install.

The installer reports precisely which of these you have, before it writes
anything.
