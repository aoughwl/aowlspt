# aowlspt

**Single-player Escape From Tarkov for the post-1.0 client.**

aowlspt is two programs and a mod ecosystem. A **host DLL** runs inside the
Escape From Tarkov client, on the Unity main thread. A **backend** runs beside
it on your own machine and answers everything the client asks a server for. The
game plays offline, against your own profile, on your own hardware.

Post-1.0 Tarkov is **IL2CPP**. There is no BepInEx and no Mono patching, so
nothing from that era loads here. aowlspt is not a fork of SPT either — the
server is re-implemented from scratch in [nimony](https://github.com/nim-lang/nimony),
and the emulator itself is written as an ordinary mod using nothing a mod
cannot use.

## Start here

| | |
|---|---|
| [Getting started](getting-started.md) | Install, first launch, your profile, your first raid |
| [Keybinds](keybinds.md) | Every key aowlspt owns, on one page |
| [Settings](settings.md) | The F12 overlay: pages, search, themes, and the honesty convention |
| [Mods](mods.md) | Every mod that ships, and what each one does |
| [The mod system](mod-system.md) | How a mod gets loaded, lists, and the mod manager |
| [For mod authors](modding.md) | The Nimony mod API, settings declaration, capabilities |
| [Troubleshooting](troubleshooting.md) | Logs, common refusals, and how to read them |

## The shape of it

```
aowlspt-launch.exe
  ├── aowlspt-backend.exe        the server: routes, database, server-side mods
  └── EscapeFromTarkov.exe       started suspended
        └── aowlspt-host-il2cpp.dll   injected, then resumed
              └── client-side mods
```

Your existing Tarkov install is only ever **read**. aowlspt builds a second
directory beside it, hard-linking the ~77 GB of asset bundles rather than
copying them, so an install costs seconds and about a gigabyte.

The modded client never talks to BSG's service. BattlEye is not carried across
and the launcher does not start it.
