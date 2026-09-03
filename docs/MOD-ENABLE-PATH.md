# Getting a new mod to STAY loaded

You built a mod, its DLL is in the install, the host log says it loaded — and a
few seconds later it is gone. Then the mod's own diagnostics say something like
"NOT ARMED (waiting out armDelayMs)". That reads as a broken mod. It is not.
The platform unloaded it before it ever got the chance.

This page is the whole rule, and the one command that fixes it.

## The four gates

A client mod runs only if **all four** are true:

1. **The DLL is on disk**, at `<install>\aowlspt\mods\<dir>\<lib>.dll`.
2. **The registry names it** — an entry in `registry/mods.json` with a matching
   `artifact.dir` / `artifact.library`, and `"client"` in its `sides`.
3. **Something SELECTS it** — an active mod list in `registry/mods.json` names
   it with `"enabled": true`, *or* the user has an enable override for it.
4. **Its `pipeline` range includes the running host version**, its `requires`
   are all satisfied, and it conflicts with nothing else enabled.

Gate 3 is the one that catches every new mod, because **nothing selects a mod by
default**. Adding it to the registry does not select it. Putting the DLL in
place does not select it. This is deliberate — a registry is a catalogue, not a
load order — but the failure was silent, and silence here is indistinguishable
from a broken mod.

## What actually happens when gate 3 is not met

The decision is made **on the server**, by `aowl.manager`, and the client host
merely obeys it:

* `mods/manager/mgr/resolve.nim` walks the active lists and the user's
  overrides. A registry mod that no list and no override mentions gets the
  verdict `vNotSelected`, reason *"no active list mentions it"*.
* `mods/manager/manager.nim:routeClient` serves that resolution at
  `GET /aowlspt/mods/client/<hostver>` as
  `{"guid":…, "enabled": verdict == loaded, "verdict":…, "reason":…}`.
  For a not-selected mod, `enabled` is **false**.
* `host/common/modcontrol.nim:applyDesired` sees a mod that is live while the
  backend says `enabled:false`, and queues an unload. That is the unload you saw.

`mods\aowlspt-selection.json` in the install is **not** where you fix this.
`aowl.manager` owns that file and rewrites it; a hand-edit is reverted.

## The supported way to enable a mod

**One request to the backend, once.** It writes a persistent user override,
which outranks every list:

```
GET https://127.0.0.1/aowlspt/mods/enable/aowl.yourmod
```

`/aowlspt/mods/disable/<id>` switches it back off; `/aowlspt/mods/clear/<id>`
removes the override and lets the lists decide again. `enable` refuses an id
that is not in the registry, so a typo cannot leave a permanent entry naming
nothing.

### What the UIs use is a DIFFERENT route — measured, 2026-09-03

The three GETs above are the **command-line** way, and they are `overrideLocked`
in `mods/manager/manager.nim`. Neither in-game UI uses them:

```
POST /aowlspt/mods/toggle/<id>   {"enabled": true|false}
```

is what the **F12 mod panel** sends (`AOWL_CMD_TOGGLE` in
`abi/aowlspt_overlay.h`) and now also what the **native MODS tab's per-mod
ENABLED switch** sends, through the same command queue rather than a second
implementation. It is `toggleLocked`: absolute state when `enabled` is present
(not a flip), a protected-row refusal, and `afterChange()` broadcast.

Instruments: the route table at `mods/manager/manager.nim:2295-2306`, and the
command leg of the overlay worker loop.

**A claim this repo carried in writing and that is false:** that the mod-enable
write is only the GET pair, and that a native switch therefore needed a
one-shot GET added to the overlay bridge. It did not — the bridge already had
the queue the F12 panel uses.

The client host picks the change up on its next poll (a few seconds) and loads
the mod live — no restart.

## The other way: ship it in a list

If the mod should be on for *everyone* rather than for one player, add it to a
list in `registry/mods.json` instead — that is a tracked file with a git
history, and it is how `aowl.maps`, `aowl.admin` and the rest are selected:

```json
{ "id": "aowl.yourmod", "enabled": true, "note": "why this is on by default" }
```

into the `entries` of `aowl.list.beta` (what the public beta ships) or
`aowl.list.vanillaplus`. Lists inherit: `beta` -> `vanillaplus` -> `core`.

## How to tell "rejected" from "broken"

Since this change the client host says so, in the host log, in the same breath
as the unload:

```
MOD REJECTED BY THE PLATFORM, not broken: aowl.ammoloading is being UNLOADED
because the backend's mod set says NOT SELECTED -- it is in the registry, but no
active mod list mentions it and there is no override for it, so nothing ever
asked for it. This is the DEFAULT state of every newly added mod and it is not a
fault in the mod. TO ENABLE IT, ask the backend once: GET
/aowlspt/mods/enable/aowl.ammoloading -- or add it to a list in
registry/mods.json. Do NOT hand-edit mods\aowlspt-selection.json; aowl.manager
owns that file and overwrites it. [the manager's own words: no active list
mentions it]. Anything aowl.ammoloading says after this about not being armed
is a CONSEQUENCE of this unload, not a cause.
```

Every verdict the manager can return has its own wording and its own named fix:
`not-selected`, `disabled`, `wrong-side` (add `"client"` to `sides`),
`pipeline` (its version range excludes this host), `missing-dependency`,
`conflict`, `cycle`. A verdict this host has no wording for is printed
verbatim rather than guessed at, and a manager too old to send a verdict is
reported as *"the backend named no verdict"* — never as a reason.

So the two cases are now distinguishable in the log, which is the point:

| you see | it means |
|---|---|
| `MOD REJECTED BY THE PLATFORM` | gate 3 or 4. The mod is fine. Enable it. |
| no rejection line, and the mod says `NOT ARMED` | the mod really did not arm. Debug the mod. |

## A worked example

`aowl.ammoloading` is a client mod with a 12-second `armDelayMs`. It was
loading, being unloaded at roughly t=5s, and then honestly reporting that it had
not armed. Nothing was wrong with it: it was in `registry/mods.json` and in no
list. It is now an entry in `aowl.list.beta`, and stays loaded.

`aowl.textures` is the same mechanism with a **deliberate** cause: it is in no
list on purpose (`"shipped": false`), because it does nothing until you install
a texture pack under its own `data/`. Enable it by hand with
`/aowlspt/mods/enable/aowl.textures` once you have a pack. The host now says so
rather than leaving it looking broken.
