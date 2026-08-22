# For mod developers

Mods are native libraries. A mod exports three C functions, is loaded by a host,
and reaches the game or the server through one small C ABI — no BepInEx, no
Harmony, no managed runtime. The ones in this repository are written in
[nimony](https://github.com/nim-lang/nimony) against `aowl/src/aowlspt.nim`.

## The shortest path to a running mod

```
aowl doctor          # nimony, gcc, lld, the headers, and PATH order
aowl run examples/hello
```

`aowl run` builds the mod and loads it into **`aowlspt-sim`** — a host with no
game and no server behind it. That takes about a second, which is the whole
point: you do not launch Tarkov to find out that your JSON is wrong.

Leave `aowlspt-sim --watch` open and it reloads the library whenever you rebuild
it. (Reload-on-change is the simulator's facility; the backend and the client
host do not watch anything, though all three can unload a mod.)

## What a mod looks like

```nim
import aowlspt
import aowlspt/game

var Player = gameType("EFT.Player")
var world = whenReady("EFT.GameWorld")

proc onUpdate(elapsedMs: int64): Status =
  if world.ready():
    info "health " & $Player.get("Health").asFloat()
    discard Player.invoke("Heal", 50)

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args
        stopWith("0.0"))            # and the original never runs
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient}, onUpdate = onUpdate)
```

Nothing here names a game type at build time. The database is addressed by
dotted path and the game is reached by string target, which is why a point
release that renames types does not break the ABI.

## Where to go next

| | |
|---|---|
| [Writing a client mod](MODDING.md) | Types, calls, live objects, hooks, config, storage, timers, locks, per-frame code, and testing without the game. |
| [Writing a backend mod](BACKEND.md) | Routes, the database, the wire protocol, HTTPS for the real client, merging, and what survives a crash. |
| [In-game settings](SETTINGS.md) | `declareSettings` — declare your values once and the F12 page draws the right control for each, persists edits back to `config.json`, and hot-applies them. |
| [Debugging](DEBUGGING.md) | Three levels, cheapest first — and the list of things that will bite. |
| [The C ABI](ABI.md) | The contract itself, and the decisions behind it. |
| [Architecture](ARCHITECTURE.md) | The whole system: the hosts, where C stops and nimony starts, a request and a hook end to end. |
| [IL2CPP](IL2CPP.md) | What the client host actually does, and what it refuses. |
| [Client performance](PERF.md) / [server](PERF-SERVER.md) | What a call costs, measured — and why there is a fast path beside the general one. |
| [The dev loop](../DEVLOOP.md) | Build times and what actually needs rebuilding. |
| [Repository layout](REPO-LAYOUT.md) | Every directory, the capability matrix, the test suite, the port map, cutting a release. |

Worked examples live in `examples/`: `hello` (the plumbing end to end),
`clientprobe` and `highlevel` (reaching into a post-1.0 client, raw and typed),
`backend` and `gameserver` (routes, database, config), and `lesson` — every part
of the API in the order a mod needs it.

## Capabilities by host

A capability a host does not have returns `ErrUnsupported` rather than
misbehaving, so `side()` guards are the normal way to write a mod that ships
everywhere. The full matrix is in
[REPO-LAYOUT.md](REPO-LAYOUT.md#what-a-mod-can-do); the short version:

- **Backend**: routes, the database (`dbGet`/`dbPatch`, which *merges* and
  creates paths that are not there), the notifier websocket.
- **Client (IL2CPP)**: `resolve`/`call` on any type and method, live objects as
  handles, fields by name, x64 detours (`hook`, `hookArgs`, `hookReturn`, and
  the typed variants for the per-frame path), `aowlspt/fast` for ~10 ns calls.
- **All three**: logging, events, config, timers, and a persistent store.

## Publishing a mod

Add it to `registry/mods.json` — that is the index every install reads, and the
lists that select sets of mods are documents in the same file. `aowl-regcheck`
checks the registry against the mods it claims to describe, and `aowl release`
refuses to build unless every mod the registry names has a library staged and
named after its directory. See [registry/README.md](../registry/README.md) and
[REPO-LAYOUT.md](REPO-LAYOUT.md#cutting-a-release).

```
aowl release --mod sway      # one mod, in the layout SPT 4.x needs
```
