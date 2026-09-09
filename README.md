# aowlspt

A modding pipeline for post-1.0 Escape From Tarkov, written end to end in
**aowlmony**: a native client host, a backend server, an in-game overlay, one
mod ABI, one build command — and a Tarkov emulator written as a mod on top of
it, using nothing a mod cannot use.

**Discontinued and unsupported.** It works; nobody is maintaining it. Build it
yourself. Development moved to [Jester](https://aoughwl.github.io/docs/jester).

```nim
proc onUpdate(): Status =
  if world.ready():                      # true once, when the game exists
    info "health " & $Player.get("Health").asFloat()
    discard Player.invoke("Heal", 50)

    discard hookArgs("EFT.Player::ApplyDamage",
      proc (target, args: string): HookResult =
        info "damage: " & args           # the arguments the game passed
        stopWith("0.0"))                 # and the original never runs
  Ok

exportMod(guid = "you.mod", name = "Mod", author = "you", version = "1.0.0",
          sptRange = "*", sides = {sideClient}, onUpdate = onUpdate)
```

## What's in it

| mod | |
|---|---|
| `sain` | bot AI — sight, hearing, threat, suppression, cover selection |
| `morebots` | bot population per map, scaled from the vanilla baseline |
| `maps` | radar, map art, direction indicators; `waypoints` covers every map |
| `voice` | conversational agents |
| `uihub` / `settingshub` | the full SPT server config surface, in-game on F12 |
| `graphics` / `dlss` / `fov` | post-process overhaul, DLSS/OptiScaler control, FOV |
| `ammoloading`, `textures`, `admintrader`, `autoraid`, `basement` | |

## Why it's built this way

SPT 4.x moved the server to C#/.NET 10, so the obvious thing would be to write
mods in C#. This doesn't, for one reason: **the same compiled mod should run
everywhere, and be debuggable without launching Tarkov.**

- One narrow **C ABI** (`abi/aowlspt_abi.h`) that neither side's language leaks
  through.
- **Three hosts** that implement it and differ only in what they can honestly
  offer: `aowlspt-backend`, the IL2CPP client host, and `aowlspt-sim` — a
  simulator with no game and no server behind it. All three load mods through
  the same `host/common/modhost.nim`.
- A **reflection escape hatch**, so nothing in the game or server is
  unreachable because the ABI hasn't grown a door for it.
- A **fast path** beside it, because general is slow — `docs/PERF.md` measures
  by how much.

**The ABI names no SPT type.** SPT renames types between point releases; a
bridge that names fifty of them breaks every release. The database is addressed
by dotted path and the game by string target through `call`. What churns
underneath is data, not a header — which is why this survived point releases
that broke everything else.

## Build

```
aowl doctor      # toolchain, ABI/cache agreement, and PATH order
aowl build
aowl test
```

Needs nimony for Windows, msys2 ucrt64 gcc plus `mingw-w64-ucrt-x86_64-lld`, the
.NET 10 SDK (for `SptReflect`, the one C# program left — it reads SPT's assembly
metadata), an SPT 4.1.x install to compile against, and a Tarkov install for
`aowlspt-install` to work from. Both game installs are **only ever read**.

`C:\msys64\ucrt64\bin` must precede Git-for-Windows' `mingw64` on PATH, or gcc
loads the wrong libgcc and dies with no diagnostic at all. `aowl doctor` checks
that first; every check in it exists because something went wrong once and
pointed somewhere else while it did.

## Where to start

**[aoughwl.com/docs/aowlspt](https://aoughwl.github.io/docs/aowlspt)** — the
full documentation, and much more of it than is in this repo: getting started,
the mods, bot AI, the emulator, the IL2CPP host, pitfalls, troubleshooting, and
the generated ABI reference.

**[Discord](https://discord.gg/nxa3W7w4rJ)** — the people who used this, and
where Jester is being built.

In the repo: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) is the whole shape
in one document — the hosts, where C stops and aowlmony starts, and how a
request and a hook travel end to end. Then
[`docs/INSTALL.md`](docs/INSTALL.md) · [`docs/ABI.md`](docs/ABI.md) ·
[`docs/EMULATOR.md`](docs/EMULATOR.md) · [`docs/IL2CPP.md`](docs/IL2CPP.md).

Everything binds loopback only and there is no flag to change it. `aowlspt-install`
is the single program that writes outside this repo, and only when told what and
where.

## Licence

[PolyForm Noncommercial 1.0.0](LICENSE) — use it, change it, share it, for any
noncommercial purpose. Commercial use is not granted.

Ships no game content. `mods/waypoints` is derived from
[SPT-Waypoints](https://github.com/DrakiaXYZ/SPT-Waypoints) by DrakiaXYZ (MIT);
each file records its own provenance.
