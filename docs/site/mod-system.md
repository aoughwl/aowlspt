# The mod system

## Three gates

A mod runs only when **all three** of these are true. This is the first thing to
check when something is not happening.

1. **The DLL is on disk.** `D:\Aowlspt\aowlspt\mods\<name>\<name>.dll`, beside
   its `config.json` and its `data\`. A mod directory with a config and no
   library installs perfectly, is loaded by nothing, and is exactly what the
   installer's verify step refuses.
2. **The registry names it.** `registry\mods.json` is the catalogue: every mod
   that exists, what it provides, what it must load after, and the lists that
   group them. A DLL the registry has never heard of is not offered.
3. **Your selection loads it.** The mod manager resolves the registry against
   your choices and writes `aowlspt-selection.json`. A mod that is installed and
   not in that document is **not started at all** — no `on_load`, no database
   writes, no routes, not one line of its own code.

Mods are matched to files by **guid**, not by filename. Each candidate library
is opened, asked what it calls itself, and put back down without being
initialised.

### No selection loads everything

Four ways of not having a selection, and all four fall back to loading every
installed mod — which is what a fresh install needs:

| the file | what happens |
|---|---|
| absent | everything loads, silently — nobody has chosen yet |
| unreadable or truncated | everything loads, with a warning naming the file |
| written for the other side | everything loads, with a note |
| `"load": []` | everything loads, with a warning |

That last one matters. A working manager always names at least itself — its own
row is protected, so a selection can never switch off the thing that would
switch it back on. An empty list is therefore never "the player chose nothing";
it is a damaged file, and honouring it would take the manager out along with
every route that could repair it.

Load **order** is the registry's `loadAfter`, resolved by the manager. It is not
a directory walk, so a mod that must come up after another one reliably does.

## Lists

A list is a named set of mods you can install or switch to in one move.

| id | name | what it is |
|---|---|---|
| `aowl.list.core` | Core | the manager and the emulator, and nothing else |
| `aowl.list.vanillaplus` | Default | the game, plus the mods that change how it feels without changing what is in it |
| `aowl.list.beta` | aowlspt beta | everything that ships |

```
aowlspt-install install ... --list aowl.list.beta
```

**Your own lists survive a registry refresh.** Local lists live in the manager's
own store, not in the registry, and are merged in at read time, so the resolver
cannot tell yours from a published one. A refresh reports what moved —
`+ [added]`, `- [removed]`, `~ [name 0.1.0 -> 9.9.9]` — and names any of your
selections that now point at a mod the new registry does not have. It does not
repair them for you: a list that quietly rewrote itself would be worse than one
that says it is broken.

## The mod manager

The manager is itself an ordinary mod (`aowl.manager`). It reads the registry,
resolves it against your selection, and serves the result — to the in-game
overlay and to the command line alike.

```
GET  /aowlspt/mods                 what is installed, and whether live control works
GET  /aowlspt/mods/panel           the same, flattened for the overlay
POST /aowlspt/mods/toggle/<id>     {"enabled":true} — set it and apply it
GET  /aowlspt/mods/apply           push the current selection at the host
GET  /aowlspt/mods/clientreport    what the client host said came of it
```

Your choice is written to the manager's own store, never into the registry, so
updating a registry checkout can never conflict with what you switched off last
night.

### Turning a mod off while everything is running

`/aowlspt/mods` reports what will actually happen, in a field called `control`:

* **`present`** — the host answered and can load and unload. Your change takes
  effect now.
* **`absent`** — a host answered but cannot unload. Your change is saved and
  takes effect on the next start.
* **`unknown`** — nothing has answered the probe yet.

A manager that reported "disabled" for a mod that was still serving would be
worse than one with no live control at all: the first is a missing feature, the
second is a lie you act on.

Server-side mods toggle live. Nothing is loaded or unloaded inside the request
that asked for it — the request is queued and drained from the host's own loop,
because unloading a mod from inside a call that is running *through* that mod
means returning into unmapped memory. When a mod is unloaded, the host drops
every route, event subscription, timer and detour it registered before freeing
the library, waits for any in-flight call to finish, and leaves the mod loaded
rather than freeing it out from under a caller that is still inside it.

## Per-mod settings

Every mod declares its settings, and the overlay draws them. See
[Settings](settings.md) for the player's view and
[For mod authors](modding.md#settings) for the declaration.

Values persist to that mod's own `config.json`, beside its DLL, and apply
without a restart.
