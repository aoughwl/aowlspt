# Configuration

Two ways to change how aowlspt behaves: the in-game settings pages, and the
`config.json` beside each mod. They are the same values — the settings page
writes back to the file.

## Where everything lives

Everything this project owns is under `<install>\aowlspt\`:

| path | what it is |
|---|---|
| `mods\<name>\config.json` | that mod's settings. Edited in game or by hand. |
| `mods\<name>\data\` | data files the mod ships with. |
| `aowlspt-host.json` | the client host: how long to wait for IL2CPP, which backend port to poll, how often. |
| `backend.json` | which port the backend serves on. Written by the installer. |
| `registry\mods.json` | every mod that exists, and the lists that name them. |
| `aowlspt-selection.json` | what the mod manager resolved: what will actually load. Yours, not the registry's. |
| `db.json` | the imported game database. |
| `aowlspt-host.log`, `aowlspt-backend.log` | the two logs. |

## In-game settings (F12)

**F12** opens the settings panel. It carries one page per mod, the Tarkov
emulator's own settings, and the full SPT server config surface (28 pages, 323
values).

A mod declares its settings once, and the panel draws the right control for each
value, persists your edit back to that mod's `config.json`, and hot-applies it
where the mod supports that. Anything the system does not yet back is marked
**not implemented yet** on the page rather than silently doing nothing — a
control that lies is worse than a control that is honest about being inert.

The panel is drawn by the aowlspt overlay rather than by Tarkov's own IL2CPP
settings screen. The reasoning, and the reverse-engineering of the real screen,
is in [SETTINGS.md](SETTINGS.md).

## Editing `config.json` by hand

Each mod's `config.json` is plain JSON, and most of them carry `//`-prefixed
sibling keys that document the value below them — `"//population"` explains
`"population"`. Those comment keys are part of the file; leave them in.

Read the mod's README for what each key means; every mod has one beside its
source, and [Mods](MODS.md) links them all.

A mod reads its config at load. Changing a file by hand while the game is
running has no effect until that mod is reloaded — which the
[mod manager](MODMANAGER.md) can do without restarting anything.

## Host settings — `aowlspt-host.json`

Three keys, each with a line above it saying what it is for:

| key | what it does |
|---|---|
| `waitForRuntimeMs` | how long the host waits for the game to bring IL2CPP up before giving up on resolving anything. |
| `backendPort` | the port the host asks for the live mod list. `0` means "do not ask", and the host falls back to the port named in `backend.json` — the file the installer writes — so an ordinary install reaches its own server without anyone editing anything. |
| `modSyncMs` | how often the host polls `/aowlspt/mods/client` for mods to load or unload while the game runs. Default 3000; `0` switches it off. |

With no backend port at all the overlay is read-only: it lists what the host
pushed into it, and a mod you switch off takes effect when the game next starts.

## Ports

Loopback only, everywhere, and there is no flag to change that. The backend
defaults to **6969** (`--port`), which is also SPT's port — the client asks
there, so the backend answers there. The full port map, including the one each
test gate reserves for itself, is in
[REPO-LAYOUT.md](REPO-LAYOUT.md#ports).

## Mod selection

Your choices live in the mod manager's store and end up in
`aowlspt-selection.json`, not in the registry and not in any `config.json`. The
`--list` you installed with seeds the first run and is not consulted again once
you have changed anything. See [MODMANAGER.md](MODMANAGER.md).
