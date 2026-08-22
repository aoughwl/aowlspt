# aowlspt

**Mods for post-1.0 Escape From Tarkov.** A native mod host, a game server that
speaks the real client's protocol, a launcher, and a set of mods — offline,
single-player, on your own machine.

Tarkov 1.0 moved the client to IL2CPP. There are no managed assemblies left, so
BepInEx does not load, Harmony has nothing to patch, and every mod written for
the Mono era stopped working. The usual answer is to roll your client back to a
pre-1.0 build. aowlspt does the other thing: it mods the client you actually
own.

```
aowlspt-install install --source D:\Games\Tarkov --target D:\Aowlspt --payload payload
aowl importdb --from D:\SPT --out D:\Aowlspt\aowlspt
aowlspt-launch --root D:\Aowlspt
```

→ **[Install it](docs/INSTALLATION.md)** · **[First run](docs/GETTING-STARTED.md)** ·
**[Mods](docs/MODS.md)** · **[All documentation](docs/README.md)**

---

## What you get

| | |
|---|---|
| **Offline raids** | Every map, with bots, generated loot, extracts and death handling. No server but yours. |
| **A working progression loop** | Profiles, the stash, traders and trading, quests with their conditions evaluated, the hideout and its production queue, the flea market, insurance, mail, skills, the scav. |
| **Bot AI worth fighting** | SAIN, rewritten natively: layered decisions, personalities, cover use, squad behaviour. MoreBots raises the population; Black Division adds a hostile PMC faction. |
| **The mods people actually run** | FOV fix, classic (no-inertia) movement, physical weapon sway, Path To Tarkov, a graphics overhaul, high-res PBR textures, resource packs, engine performance settings. |
| **In-game settings** | A settings page per mod, edited while the game runs, persisted back to the mod's `config.json`. |
| **A mod manager** | Enable and disable mods live — on the server while it serves, and on the client while the game is running. Mod lists are files you can commit and send someone. |
| **A mod API** | Write mods in [nimony](https://github.com/nim-lang/nimony) against one small C ABI, build them with one command, and test them without launching Tarkov. |

## Who this is for

- **Players** who want a modded single-player Tarkov on a post-1.0 client, and
  are willing to run an installer and import a database once.
- **Mod authors** who want to reach a post-1.0 client at all — hooks, live
  objects, fields by name, and a per-frame fast path, with no BepInEx
  underneath.

## Scope, plainly

- **Single-player and offline only.** PvE. The client this produces plays
  against a backend on your own machine.
- **It must never talk to BSG's live service.** The installer does not carry
  BattlEye across and the launcher does not start it. Injecting a DLL into a
  process that is talking to BSG's servers has consequences for your account.
  These tools will not stop you pointing the client somewhere else, and they
  will not help you either.
- **Your existing install is only ever read.** Everything is built into a second
  directory. If it goes wrong, delete that directory.
- **You need an SPT install to import the game's data from.** The item, trader,
  quest and map tables are BSG's data by way of SPT's, and this project does not
  distribute them. Without that step the server starts, answers every route, and
  has nothing in it.
- **Windows only.**

## Status

This is a young project and it is honest about what it has proved. `aowl test`
runs the whole system — the ABI's layout under the real compiler, the detour
engine, the client host against a stand-in IL2CPP runtime, the backend over its
own wire framing, the emulator through the client's boot sequence, a long soak,
a hostile client, and every mod in the registry loaded at once. **What automated
tests cannot establish is that BSG's client behaves like the stand-in**; that
part is settled by launching and reading `aowlspt/aowlspt-host.log`.

Anything a mod's page marks *in progress* or *pending live validation* is
exactly that. [docs/BACKLOG.md](docs/BACKLOG.md) is the standing list of what is
undone, broken or unanswered.

## Documentation

Start at **[docs/README.md](docs/README.md)** — installation, first run, the mod
catalogue, configuration, troubleshooting, the mod-authoring guide, and the
internals.

## Licence

See [LICENSE](LICENSE). Ported mods carry their upstream licence in their own
directory, unchanged; each one names its original author.
