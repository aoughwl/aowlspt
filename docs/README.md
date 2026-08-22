# aowlspt documentation

Everything about installing, playing, configuring and extending aowlspt — the
native mod system for post-1.0 Escape From Tarkov.

New here? [Installation](INSTALLATION.md) → [Getting started](GETTING-STARTED.md)
→ [Mods](MODS.md).

## Getting started

| | |
|---|---|
| [Installation](INSTALLATION.md) | Requirements, the five commands, and what lands where. |
| [Getting started](GETTING-STARTED.md) | Your first launch: the launcher, the profile, the menu, the first raid. |
| [Installer reference](INSTALL.md) | The long version — every step, every flag, every refusal and what to do about it. |
| [Importing the game's data](IMPORTDB.md) | Building `db.json` out of an SPT install. Mandatory, and not part of the installer. |

## Using it

| | |
|---|---|
| [Mods](MODS.md) | Every mod that ships in this repository, what it does, and what it is for. |
| [Configuration](CONFIGURATION.md) | `config.json` per mod, the in-game settings pages, and where each file lives. |
| [Mod manager](MODMANAGER.md) | Turning mods on and off — including while the server serves and the game runs. |
| [Troubleshooting](TROUBLESHOOTING.md) | The failures people hit, in the order they hit them, and the log line that identifies each. |
| [FAQ](FAQ.md) | Short answers: pre-1.0, multiplayer, BattlEye, SPT, updates, uninstalling. |

## For mod developers

| | |
|---|---|
| [Start here](FOR-MOD-DEVELOPERS.md) | What a mod is, the build command, and the shortest path to a running one. |
| [Writing a client mod](MODDING.md) | Types, calls, live objects, hooks, config, storage, per-frame code. |
| [Writing a backend mod](BACKEND.md) | Routes, the database, the wire protocol, and what survives a crash. |
| [In-game settings API](SETTINGS.md) | Declaring your mod's settings so the F12 page can draw them. |
| [Debugging](DEBUGGING.md) | Three levels, cheapest first — the simulator, a debugger, the real host. |
| [The dev loop](../DEVLOOP.md) | Build times, what to rebuild, and the loop that does not need a human in it. |
| [Repository layout](REPO-LAYOUT.md) | Every directory and what is in it; the test suite; the port map; cutting a release. |

## Internals

Reverse-engineering notes, measurements and design records. Useful, and not on
anybody's path to playing the game.

| | |
|---|---|
| [Architecture](ARCHITECTURE.md) | The whole system in one document: the hosts, the ABI, a request end to end. |
| [The C ABI](ABI.md) | The contract every host implements, and the decisions behind it. |
| [IL2CPP](IL2CPP.md) | Why there is no BepInEx underneath the client host, and what replaces it. |
| [The wire protocol](WIRE.md) | What a post-1.0 client actually puts on the wire. |
| [The emulator](EMULATOR.md) | What the game server implements. |
| [Emulator coverage](EMULATOR-COVERAGE.md) | Every client operation, served or not. Generated — see [coverage-rows.json](coverage-rows.json). |
| [Emulator refusals](EMULATOR-REFUSALS.md) | What it deliberately does not do, and why. |
| [Captured routes](CAPTURE-GAP.md) | The real client's routes against the ones we serve. |
| [Capture timeline](CAPTURE-TIMELINE.md) | What the client does, in order, over a whole session. |
| [Captured responses](CAPTURE-RESPONSES.md) | The bodies themselves. |
| [Post-1.0 data delta](POST1-DATA-DELTA.md) | The pre-1.0 database against post-1.0's own data. |
| [API gaps](API-GAPS.md) | Where the mod API is not yet enough, with the case that shows it. |
| [Client performance](PERF.md) | What a client-side call costs, measured. |
| [Server performance](PERF-SERVER.md) | What a request costs, measured. |
| [The debug overlay](DEBUG-OVERLAY.md) | The in-game diagnostic panel. |
| [Backlog](BACKLOG.md) | Everything not done, triaged: broken, blocked, awaiting playtest, open question. |
| [timbuktu/](timbuktu) | The NPC/world layer: API, persistence, story generation, settings RE. |

---

**Scope:** single-player, offline, PvE, Windows, post-1.0 clients only. The
client this produces must never talk to BSG's live service — see
[FAQ](FAQ.md#is-this-safe-for-my-account).
