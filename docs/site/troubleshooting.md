# Troubleshooting

## The two logs

Between them these answer almost every question.

| file | what it holds |
|---|---|
| `D:\Aowlspt\aowlspt\aowlspt-host.log` | the client host: which mods loaded, what it resolved in IL2CPP, every detour it installed or refused |
| `D:\Aowlspt\aowlspt\aowlspt-backend.log` | the server: which mods loaded, which routes exist, what the mod manager resolved |

The client's own Unity logs are under `D:\Aowlspt\Logs\<timestamp>\`.

## The game seems to have hung on startup

It probably has not. A cold client takes **well over a minute** to reach profile
select, and then waits indefinitely for you. An idle game and a hung one look
identical from outside.

Before deciding it crashed: wait, then check whether `aowlspt-host.log` has
actually **stopped** progressing. A log still ticking is a game that is fine.

## Nothing has any items, traders or quests in it

You skipped step 4 of [Getting started](getting-started.md), or `db.json` landed
in the wrong directory. It belongs at `D:\Aowlspt\aowlspt\db.json` — inside
`aowlspt\`, not at the install root.

`aowlspt-verify` says so explicitly, as a warning rather than a failure:

```
warn  there is no D:\Aowlspt\aowlspt\db.json, so the emulator answers out of
      its own fallbacks: it will serve, and the client will find no items,
      no traders and no quests.
```

A `db.json` under about 4 MB gets its own warning, because a real import is tens
of megabytes and anything smaller is a fixture or a half-written file.

## A mod is installed but nothing it does is happening

Walk the [three gates](mod-system.md), in order: the DLL is on disk, the
registry names it, your selection loads it. The mod manager's panel tells you
which gate you are stuck at, and `aowlspt-backend.log` names every mod it loaded
at startup.

## A setting is greyed out and will not move

That is deliberate, and it means what it says: the setting exists and is
carried, and nothing acts on it yet. See
[the honesty convention](settings.md). Press **F8** to hide every such row if
you would rather not see them.

## The game refuses to start after I edited something in the install

The client checks that the files in its own manifest have not changed **size**.
Everything aowlspt owns lives under `D:\Aowlspt\aowlspt\` and is safe to edit;
files the client owns are not.

## Starting over

`aowlspt-install.txt` at the root of the install records exactly what was
created. Delete the target directory and re-run the install — the source install
your official launcher maintains was never written to.
