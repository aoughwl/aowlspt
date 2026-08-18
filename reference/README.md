# reference/

`spt-4.1-surface.{txt,json}` is the public API surface of the **SPT 4.x server
assemblies**, dumped by `tools/SptReflect`:

```
dotnet tools/SptReflect/bin/Release/net10.0/sptreflect.dll D:\SPT\SPT_Runtime \
  --members --json reference/spt-4.1-surface.json
```

It is metadata only — nothing here was executed, and nothing was written into
the SPT install to produce it.

**aowlspt does not build against SPT.** SPT 4.x targets a pre-1.0, Mono client;
this project's backend is `aowlspt-backend` in nimony and its client host is
native. The `host/Aowlspt.Host.Server` mod that used to run inside SPT's server
has been deleted.

What this dump is still for: the ~590 `SPTarkov.Server.Core.Models.Eft` types
and the `Callbacks`/`Controllers` classes beside them name every route the
Tarkov client calls and the shape of what it sends and expects back. That is the
specification `mods/tarkov` (the emulator) has to satisfy, and it is unaffected
by the Mono-to-IL2CPP change, because the wire protocol is the same protocol.
Read it as documentation of the game's backend, not as an API this repo links
against.
