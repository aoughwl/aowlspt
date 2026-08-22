# FAQ

## What is aowlspt, in one sentence?

A native mod system for post-1.0 Escape From Tarkov: a host that loads mods into
the IL2CPP client, a server that speaks the client's real protocol, a launcher,
and a set of mods — all offline, on your own machine.

## Does it work on my version of Tarkov?

Post-1.0 clients (1.0.0 and later) only. Run
`aowlspt-install detect` and it will tell you what you have.

## Why not just use BepInEx / SPT?

Tarkov 1.0 moved the client from Mono to IL2CPP. There are no managed
assemblies left — only `GameAssembly.dll` and `global-metadata.dat` — so BepInEx
has no runtime to load into and Harmony has no methods to patch. Nothing built
for one loads into the other.

SPT 4.1.2 targets `0.16.9.40743`, a pre-1.0 Mono client, and the usual way
people run it is to roll a current client backwards to that build. **This
installer refuses to do that, and `--force` does not enable it** — a downgrade
across a major release replaces the client's assemblies and asset bundles with
an older game's, and it means the game you play is not the game you own.

So aowlspt does the other thing: it hosts mods in the post-1.0 client directly.
Unity's IL2CPP runtime exports its whole C API from `GameAssembly.dll`, so the
client host is a native DLL that drives it — no BepInEx, no Il2CppInterop, no
generated proxy assemblies, no second runtime in the process.

## Do I still need SPT installed?

Yes, for one step: importing the game's data. The item, trader, quest and map
tables are BSG's data by way of SPT's, and this project does not distribute
them. `aowl importdb` reads your SPT install read-only and writes a `db.json`.

Without it, the server starts, answers every route the client asks, and the game
is empty.

## Is this multiplayer?

No. Single-player, offline, PvE. Raids are populated by bots. There is no
matchmaking, no other players, and no plan documented here to add either.

## <a id="is-this-safe-for-my-account"></a>Is this safe for my account?

**The client this produces must never talk to BSG's live service.** The
installer does not carry BattlEye across and the launcher does not start it,
because the modded client plays against a backend on your own machine.

Injecting a DLL into a process that is talking to BSG's servers is a decision
with consequences for your account. These tools will not stop you pointing the
client somewhere else, and they will not help you either.

## Will it touch my existing Tarkov install?

No. `--source` is opened read-only and never written to; everything is built
into a second directory (`--target`), which must be beside the source and not
inside it. If it goes wrong, delete that directory — the install your launcher
maintains is untouched and still updatable.

## Does it need 78 GB of disk?

About 1 GB, on the same volume. The asset bundles nothing ever writes to are
hard linked rather than copied, so a full install appears in seconds. Everything
a patcher could plausibly rewrite is copied even so, because a hard link is a
second name for the same bytes. `--copy` turns linking off entirely.

## How do I update?

Rebuild or download the new release, then install with a payload containing only
`aowlspt/` and no `--source`. It becomes an overlay that owns only what it
added, and nothing re-links forty thousand files.

## How do I uninstall?

```
installer\build\aowlspt-install.exe uninstall --target D:\Aowlspt
```

It removes exactly the paths `aowlspt-install.txt` names and nothing else. For a
full install that is the target directory including its copy of the client; for
an overlay it is only what was added.

## Can I turn mods on and off without restarting?

Yes, on the server while it is serving. On the client, while the game is
running, if the host has a backend port to poll. `disable` and `enable` record
the decision; `/aowlspt/mods/apply` performs it. See
[MODMANAGER.md](MODMANAGER.md).

## Can I write mods in C#?

No. Mods are native libraries built against a small C ABI, and the ones here are
written in [nimony](https://github.com/nim-lang/nimony). Any language that can
produce a DLL exporting three C functions can host a mod; nimony is what has a
library and a build command. See
[For mod developers](FOR-MOD-DEVELOPERS.md).

## Does it run on Linux or macOS?

No. Windows only.

## What is `timbuktu`?

An NPC and world layer built on top of aowlspt — its notes live in
[docs/timbuktu](timbuktu). Separate from playing modded Tarkov.

## How finished is this?

`aowl test` exercises the whole system on every run, from the ABI's layout under
the real compiler to every mod in the registry loaded into one backend at once.
What automated tests cannot establish is that BSG's client behaves like the
stand-in IL2CPP runtime they run against; that is settled by launching and
reading `aowlspt-host.log`.

[BACKLOG.md](BACKLOG.md) is the standing list of what is undone, broken, blocked
or unanswered, and it is kept honest on purpose. Anything a mod's page marks *in
progress* or *pending live validation* is exactly that.
