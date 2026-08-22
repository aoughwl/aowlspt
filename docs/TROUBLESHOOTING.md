# Troubleshooting

Start with the two logs. Between them they answer nearly every question:

```
<install>\aowlspt\aowlspt-host.log       the client host: which mods loaded, what it resolved
<install>\aowlspt\aowlspt-backend.log    the server: which mods loaded, which routes exist
```

And run the check that talks to the install rather than guessing at it:

```
installer\build\aowlspt-verify.exe --root D:\Aowlspt
```

Read the failures **and the warnings** — the warnings are the interesting part.
Do not read the check count off any page; it moves as mods are added.

## The game has nothing in it

Traders sell nothing, there are no items, no quests, no maps.

**You have not imported a database.** The server is fine and it is empty. This
is step 4 of [Installation](INSTALLATION.md), it is not part of the installer,
and `aowlspt-verify` reports it as a warning:

```
warn  there is no D:\Aowlspt\aowlspt\db.json, so the emulator answers out of
      its own fallbacks: it will serve, and the client will find no items, no
      traders and no quests.
```

The other way to get this is putting `db.json` in the wrong place. **`--out` is
the `aowlspt\` directory inside the install, not the install root.** One level
up and the server comes up on its fallbacks with nothing saying why.

A `db.json` under about 4 MB gets its own warning: a real import is tens of
megabytes, and anything smaller is a test fixture or a half-written file.

## The installer refuses

Every refusal names the fact it is refusing on. Two cannot be overridden.

| message | what it means | what to do |
|---|---|---|
| **"this payload would downgrade you across 1.0"** — not overridable | Your client is 1.x, the payload was built for a 0.x one. A downgrade across a major release is not a patch; it replaces the client's assemblies and asset bundles with an older game's. | Get or build a payload for your client: set `targetTarkovVersion` to what `detect` reports. |
| **"scripting backend mismatch"** — not overridable | The payload declares `mono` and the client is IL2CPP, or the reverse. No version flag settles that. | Fix `targetBackend` in `payload.json`, or accept that you have a payload for a different game. |
| **"client version unreadable" / "client layout unrecognised" / "not a Tarkov install"** | `--source` is not a complete install, or the executable has no version resource. | Point `--source` at the folder holding `EscapeFromTarkov.exe`; let the official launcher finish a partial download. |
| **"payload is older / newer than the client"** | The numbers do not match. | Update the game or rebuild the payload — or `--force` if you know the pair works. |
| **"the source is already an SPT install"** | `SPT_Runtime` is in `--source`. Installing from an already-patched copy carries its patches forward invisibly. | Point `--source` at the vanilla install. |
| **"this registry defines no list called …"** | `--list` names a list `mods.json` does not have; you would get an install with every mod off and no reason given. | Use `--list none` or a list the registry defines — `plan` prints how many it found. |
| **"no aowlspt install manifest in …"** (uninstall) | `aowlspt-install.txt` is missing, and nothing is removed without it. | If it was a full install, the target is entirely the installer's and deleting the directory is the same operation. |

## The payload will not build

| message | what it means |
|---|---|
| `mod <name> has no library; its config and data would install as a directory nothing loads` | The mod failed to compile. `aowl build` exits 1 when any mod fails — read the exit code, not just the output. |
| `the IL2CPP client host is not built` | The install would start the game with no mods in it. Same for a missing backend (the client has nothing to talk to) and a missing launcher (no way to start the game at all). |
| gcc dies with no diagnostic at all | **PATH order.** `C:\msys64\ucrt64\bin` must come before Git-for-Windows' `mingw64\bin`, or gcc gets a `cc1` that loads the wrong libgcc and exits silently. `aowl doctor` checks this and is worth the whole command for it. |

## The game starts and no mods are in it

- **Check `aowlspt-host.log` first.** It says which mods it found, which it
  loaded, and what it could resolve in the IL2CPP runtime.
- **A mod's directory must hold a library named after itself.** The host finds a
  mod by scanning for `<dir>\<dir>.dll`; a wrongly named one installs as a
  directory nothing loads, silently. `aowlspt-verify` checks exactly this.
- **A mod that is not in your selection never runs a line of its own code.** The
  host reads `aowlspt-selection.json` before it opens anything: each candidate
  is loaded, asked what it calls itself, and put straight back down without
  being initialised. `"not-selected"` in the manager's report means not running.
- **Four ways of having no selection at all** — the file absent, unreadable,
  written for the other side, or naming an empty load list — and all four load
  everything, which is what a fresh install needs.

## The launcher exits, or the game closes immediately

- **If the launcher cannot inject, it kills the client rather than resuming
  it.** That is deliberate: a game running without its host is worse than no
  game, because you would be in a raid before noticing. The log says why the
  injection failed.
- **The launcher waits for the backend** to actually answer on its port before
  starting the client, printing a line every five seconds, and gives up after
  `--backend-wait` seconds (300 by default) with a warning. If it gives up, the
  backend did not finish loading its mods — read `aowlspt-backend.log`.
- **Run the two halves separately** to see which one is unhappy:
  ```
  aowlspt-backend.exe --root D:\Aowlspt\aowlspt --port 6969
  aowlspt-launch.exe --no-backend
  ```

## A mod I switched off is still doing things

`disable` and `enable` record a decision; **`/aowlspt/mods/apply` performs it**.
The reply to a disable says so. A route belonging to a disabled mod keeps
answering until you apply.

On the client, live loading and unloading needs `backendPort` set in
`aowlspt-host.json` (or a `backend.json` for it to fall back to). Without one,
the change takes effect the next time the game starts. See
[MODMANAGER.md](MODMANAGER.md).

## `curl` gets a 200 with a body I cannot read

The server reads every request body through a zlib stream, because the real
client always speaks compressed. A plain JSON body fails to inflate *before any
router is consulted*, so a malformed request presents as a broken mod.

Use `aowlprobe`, which speaks the protocol:

```
installer\build\aowlprobe.exe http://127.0.0.1:6969/aowlspt/status --expect '"ok":true'
```

One detail that cost time to find: the session id must be a 24-character hex
MongoId, or the request is rejected before any route sees it.

## Stopping the server

There is no shutdown route and no console handler. `--wait` terminates the
backend when the game exits, and closing its window does the same. That is safe
by design — a profile write is a temporary file renamed over the key, so there
is no half-written value to find afterwards — but "stop the server" and "kill
the server" are the same operation here.

## Writing a mod and something is subtly wrong

See [DEBUGGING.md](DEBUGGING.md), and in particular its "Things that will bite":
borrowed slices, small-string optimisation, which side of the boundary owns an
allocation, Unity's main thread, globals that a `--app:lib` build silently
leaves zeroed, and raw pointers held across a frame while the collector moves
things.

## It still does not work

[BACKLOG.md](BACKLOG.md) is the standing list of what is known to be broken,
blocked, awaiting a playtest, or an open question. Check there before assuming
it is your install.
