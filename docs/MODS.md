# Mods

Every mod that ships in this repository. Each one has a README beside its source
with the full detail, its configuration, and — for ports — its upstream licence,
carried across unchanged with the original author named.

`registry/mods.json` is the index: every mod, and every named **list** that
selects a set of them. A list is a document, so "my raid night setup" is
something you commit and send someone rather than a screenshot of a folder. To
turn mods on and off, see the [Mod manager](MODMANAGER.md).

## Core

These are the system, not content.

| mod | side | what it does |
|---|---|---|
| [Tarkov emulator](../mods/tarkov) `aowl.tarkov` | server | The game server: profiles, the stash, traders and trading, the flea market, quests with their conditions evaluated, the hideout and its production queue, raids with generated loot, bots and scavs, skills, insurance, mail. Written entirely on the public mod API. |
| [Mod manager](../mods/manager) `aowl.manager` | server | Reads the registry, resolves it against your selection, and serves the answer — including *why* a mod is not loading — under `/aowlspt/mods`. |
| [Settings hub](../mods/settingshub) | client | The in-game settings pages behind F12: one page per mod, drawn from what each mod declares. |

## Feel and visuals

| mod | side | what it does |
|---|---|---|
| [FOV Fix](../mods/fov) `aowl.fovfix` | client | Fontaine's *Fontaine-FOVFix*, rewritten natively. Optic and non-optic FOV multipliers, camera distance offsets, a zoom toggle. CC BY-NC-SA 3.0. |
| [Classic Movement](../mods/classicmovement) `aowl.classicmovement` | client | TheBoogle's *Old Tarkov Movement*: no inertia, quick tilting, no bush slowdown, optional nostalgia mode — and the same for bots. MIT. |
| [SPT-SWAY](../mods/sway) `com.savannt.sptsway` | client | Five physically modelled sources of weapon sway — respiration, cardiac, tremor, postural drift, weapon inertia — summed, scaled by the shooter's condition and the weapon, and pushed into BSG's own rotation springs. |
| [Graphics](../mods/graphics) `aowl.graphics` | client | A togglable full-frame post-processing stack: tonemapping, exposure, contrast, saturation, temperature. Ported and expanded from `TarkovGraphics`. Defaults are still being tuned against real raids. |
| [Textures](../mods/textures) `aowl.textures` | client | High-res PBR texture replacement from [ambientcg](https://ambientcg.com) sets, with a quality tier and a VRAM budget. |
| [Resource packs](../mods/resourcepacks) | client | Swapping whole packs of game resources, with a drive-grade setting so a slow disk is not asked to do a fast disk's job. |
| [Performance](../mods/perf) `aowl.perf` | client | Engine-level quality, HUD, application and time settings, plus a frame sampler. |

## Bots, factions and maps

| mod | side | what it does |
|---|---|---|
| [SAIN](../mods/sain) `aowl.sain` | server + client | Solarint's SAIN, rewritten: layered decisions, per-bot personalities, real cover use, searching that looks like searching, squads that behave like squads. ~64,000 lines of BepInEx C# reimplemented against the native API. |
| [MoreBots](../mods/morebots) `aowl.morebots` | server + client | Two jobs, as upstream had them: the bot-type and faction API other mods register against, and the mod that raises how many bots a map runs. CC BY-NC-SA 4.0. |
| [Black Division](../mods/blackdivision) `aowl.blackdivision` | server | A hostile PMC faction — six roles with their own names, gear, difficulty and spawn behaviour — on top of MoreBots. MIT. |
| [Icebreaker](../mods/icebreaker) `aowl.icebreaker` | server | The nuclear icebreaker BOREAS, locked in arctic ice: a map, delivered by rebinding the dormant `suburbs` location slot. MIT. |
| [Path To Tarkov](../mods/pathtotarkov) `aowl.pathtotarkov` | server | The deploy screen stops being a teleporter. You are standing somewhere, you may only go where that place connects to, and the map you climb out onto is where you now are. |

## Tools

| mod | side | what it does |
|---|---|---|
| [Admin panel](../mods/admin) | client | **F6** for an in-game menu of togglable cheat modes: ESP, god mode, infinite stamina, no recoil, no weight, instant heal, unlimited ammo, thermal and night vision, fly, teleport. ESP and god mode default on; everything else off. |

## Mod lists

| list | what it selects |
|---|---|
| `aowl.list.core` | The mod manager and the game server. The minimum that can serve. |
| `aowl.list.vanillaplus` | Core plus the mods that change how the game feels without changing what is in it: FOV, sway, classic movement, performance, textures. **The default for a fresh install.** |
| `aowl.list.raidnight` | Vanilla Plus with the bots turned up: MoreBots, SAIN, Black Division, Icebreaker and Path To Tarkov on top. |
| `aowl.list.headless` | Raid Night as a server operator wants it: the same content, with the client-only feel mods switched off. |

## A note on the registry

`registry/mods.json` is at revision 2 and does not yet name every mod in
`mods/` — the graphics, resource-pack, admin and settings-hub mods have no entry yet. `aowl-regcheck` is the tool that checks the registry against the
mods it claims to describe; if a mod is installed but not listed, the manager
reports it as an unmanaged stray rather than pretending it is not there. See
[registry/README.md](../registry/README.md).
