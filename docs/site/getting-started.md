# Getting started

## What you need

- A **post-1.0** Escape From Tarkov install, 1.0.0 or later, the one your
  official launcher maintains. Pre-1.0 clients are not supported.
- **Windows.** Nothing else — no .NET runtime, no Python, no PowerShell.
- About **1 GB** of free disk on the same volume as that install. Not 78 GB:
  the asset bundles are hard-linked.
- An **SPT install** to import the game's data from, once. See step 4.

Your existing install is opened read-only and never written to. If anything
here goes wrong, delete the new directory; the install your launcher maintains
is untouched and still updatable.

## 1. Find your client

```
install\aowlspt-install.exe detect
```

```
D:\Games\Tarkov
---------------
  root      D:\Games\Tarkov
  version   1.1.0.46777
  backend   IL2CPP
  suitable  yes — this is a post-1.0 client
```

Write the version down. If your install lives somewhere unusual, name it:
`aowlspt-install detect E:\Tarkov`.

## 2. Preview the install

```
install\aowlspt-install.exe plan ^
    --source D:\Games\Tarkov ^
    --target D:\Aowlspt ^
    --payload payload
```

`plan` prints the client it found, the mods it will install, every objection it
has, and the exact list of steps — then does nothing. That list is not an
approximation of the install; it is the same list, executed.

`--source` is read-only. `--target` is a new directory beside it — not inside
the source, and not the source itself; both are refused.

## 3. Install

```
install\aowlspt-install.exe install ^
    --source D:\Games\Tarkov ^
    --target D:\Aowlspt ^
    --payload payload
```

It prints the plan, asks once, and does it. `--yes` skips the question, which is
what a script wants and not what you want the first time.

What lands in `D:\Aowlspt`:

```
D:\Aowlspt\
  EscapeFromTarkov.exe          copied
  EscapeFromTarkov_Data\        mostly hard-linked
  aowlspt\
    aowlspt-launch.exe
    aowlspt-backend.exe
    aowlspt-host-il2cpp.dll
    backend.json                where the client looks for the backend
    mods\
    registry\mods.json
  aowlspt-install.txt           what was created, for uninstall
```

Useful flags:

- `--list ID` — which [mod list](mod-system.md#lists) a fresh install starts
  with. Default is `aowl.list.vanillaplus`.
- `--overlay` — rewrite only the aowlspt payload into a target that already has
  a client, which is what you want after an update.
- `--copy` — copy the bundles instead of hard-linking them.
- `--dry-run` — print every step and execute none.

## 4. Give it the game's data

**This step is not optional.** Everything above produces a complete, verifiable,
*empty* server: it answers every route the client asks out of the emulator's own
fallbacks, with no items, no traders, no quests and no maps in any of them. The
payload does not carry a database and cannot — that data is BSG's.

```
install\aowl-importdb.exe --from D:\SPT --out D:\Aowlspt\aowlspt
```

About three seconds and ~39 MiB later there is a `db.json` where the backend
looks for it. **`--out` is the `aowlspt\` directory inside the install, not the
install root.** Put it one level up and the server comes up on its fallbacks
with nothing anywhere saying why.

The importer opens the SPT install read-only and refuses an `--out` inside it.

## 5. Check it

```
install\aowlspt-verify.exe --root D:\Aowlspt
```

This is the one worth running. It checks the client is post-1.0 and IL2CPP, that
the host, launcher and backend are present, that every mod directory holds an
actual library and not just a config nobody reads, that the registry went in and
the default list is one the registry defines — and then it starts the backend on
a spare port, asks it the first four questions the client asks, and stops it.

```
Result
------
  36 checks
  0 warning(s)
ok    this install is complete and serves
```

Read the failures and the warnings, not the count — it moves as mods are added.
The last line is exact about what was proved: `--offline` starts nothing and
says so, printing "the files of this install are all present" instead.

**The warnings are the interesting part.** A missing `db.json` is a warning, not
a failure: the install is not broken, there is just no game in it, and those are
two different sentences.

## 6. Play

```
D:\Aowlspt\aowlspt\aowlspt-launch.exe
```

The launcher starts the backend, waits for it to actually answer on its port,
then starts `EscapeFromTarkov.exe` **suspended**, loads the host DLL into it and
resumes. The game comes up with the host already inside it and nothing in the
install pretending to be a Windows component — no `winhttp.dll`, no doorstop, no
BepInEx.

- `--wait` keeps the launcher open until the game exits, then stops the backend.
- `--no-backend` starts the client alone, when a backend is already running.
- `--dry-run` reports what it would start and starts nothing.

Boot to first answer is about **3 seconds** for the server with a full mod set
and an imported database. The client itself takes considerably longer to reach
the menu on a cold start — the host waits for the game to bring IL2CPP up before
it can resolve anything.

## 7. Your profile

The first screen is the mode selector, then character slots. Create a profile:
pick a side, pick an appearance, pick a nickname — the nickname is validated
against the same rules the live game uses — and you land in the hideout.

The profile is stored server-side by the emulator and survives restarts. Your
scav is a second character on the same profile, sharing the PMC's stash rather
than copying it, with its own cooldown and its own Fence standing.

## 8. Your first raid

From the main menu, pick a map, a time of day and a spawn, and go. The raid is
offline: bots are generated by the backend by role and difficulty, dressed out
of the database's own loadout, mod and ammo tables, and they carry what those
tables put in their rig, pockets and pack. Loot is generated too — static
containers, loose loot, ammo boxes, weapon presets expanded.

Extract and the raid ends properly: what you carried out stays, what you lost is
gone, insurance returns arrive by mail from the trader who insured them, and your
skill and mastering deltas run through the game's own curve.

Press **F12** at any point to open [the settings overlay](settings.md).
