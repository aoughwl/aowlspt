# Getting started

You have installed aowlspt and imported a database
([Installation](INSTALLATION.md)). This is what the first session looks like.

## Start the game

```
D:\Aowlspt\aowlspt\aowlspt-launch.exe
```

The launcher does three things in order:

1. Starts `aowlspt-backend.exe` and **waits until it actually answers** on
   `127.0.0.1:<port>` — a socket that accepts is exact, because the backend
   opens the port only after the last mod has loaded. It prints a line every
   five seconds while it waits and gives up after `--backend-wait` seconds (300
   by default) with a warning rather than silently.
2. Starts `EscapeFromTarkov.exe` **suspended**, loads
   `aowlspt-host-il2cpp.dll` into it, and resumes.
3. If it cannot inject, it **kills the client rather than resuming it** — a game
   running without its host is worse than no game, because you would be in a
   raid before noticing.

Nothing in the install pretends to be a Windows component: no `winhttp.dll`, no
doorstop, no BepInEx.

Useful flags:

| | |
|---|---|
| `--dry-run` | report what it would start, start nothing |
| `--wait` | keep the launcher open until the game exits, then stop the backend |
| `--no-backend` | start the client alone, when a backend is already running |

Want the server in its own window? Start it yourself and launch with
`--no-backend`:

```
D:\Aowlspt\aowlspt\aowlspt-backend.exe --root D:\Aowlspt\aowlspt --port 6969
D:\Aowlspt\aowlspt\aowlspt-launch.exe --no-backend
```

**Stopping the server is killing it.** There is no shutdown route; `--wait`
terminates the backend when the game exits, and closing its window does the
same. That is safe by design rather than by luck — a profile write is a
temporary file renamed over the key, so there is no half-written value to find
afterwards.

## On a cold launch

The host waits for the game to bring the IL2CPP runtime up before it can resolve
anything, which takes a while; `aowlspt-host.json` sets how long
(`waitForRuntimeMs`).

The backend is the slow half. Measured on the development machine with the
default mod set and a 39 MiB imported database: the emulator alone answers in
**0.6 s**, and a full payload in about **2.9 s**.

## The two logs

Between them they answer nearly every question you will have.

| file | what it holds |
|---|---|
| `D:\Aowlspt\aowlspt\aowlspt-host.log` | the client host: which mods loaded, what it could resolve in IL2CPP |
| `D:\Aowlspt\aowlspt\aowlspt-backend.log` | the server: which mods loaded, which routes exist, what the mod manager resolved |

If something is wrong, start there — [Troubleshooting](TROUBLESHOOTING.md) is
organised around the lines you will find in them.

## In the game

- **Your profile.** The server keeps profiles and they survive a restart — the
  first-run gate asserts exactly that, with the profile still in it.
- **F12** opens the settings pages: one page per mod, plus the emulator's own
  settings and the server config surface. Edits are written back to the mod's
  `config.json` and hot-applied where the mod supports it. See
  [Configuration](CONFIGURATION.md).
- **F6** opens the admin panel, if `aowl.admin` is enabled — ESP, god mode,
  no-recoil, fly, teleport and the rest.
- **Raids are offline.** Pick a map, deploy, and you get a populated raid: bots
  by faction and role, generated loot, extracts, insurance and death handling.
  There is no other player and there is no matchmaking.

## The mod set you installed with

A fresh install starts on `aowl.list.vanillaplus`: the game server plus the five
mods that change how the game feels without changing what is in it — the FOV
fix, classic movement, sway, the performance settings and the texture pack. Two other lists
ship in the registry — `aowl.list.raidnight` turns the bot population up and
adds the AI and faction mods, `aowl.list.core` is the minimum that can serve.

To change what is running, see [Mods](MODS.md) and the
[Mod manager](MODMANAGER.md). Mods can be turned on and off while the server is
serving, and client-side mods while the game is running.

## What to do next

- [Mods](MODS.md) — what ships, and what each one is for.
- [Configuration](CONFIGURATION.md) — where the settings live.
- [Troubleshooting](TROUBLESHOOTING.md) — when it does not do the above.
- [For mod developers](FOR-MOD-DEVELOPERS.md) — writing your own.
