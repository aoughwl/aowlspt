# AutoRaid

Enter — and leave — a raid without touching the mouse.

**It ships inert.** With no command-line argument and `hotkeys` false, this mod
polls no key, draws nothing, and makes no call into the game at all.

---

## The three features

### 1. A raid from the command line

```
aowlspt-launch --raid="Woods"
aowlspt-launch --raid="Ground Zero" --raidside=scav
```

The launcher forwards anything it does not recognise as `-aowl.<name>=<value>`,
so `--raid="Woods"` reaches the client as `-aowl.raid=Woods`. The host parses
every such token once at boot; this mod declares the two it reads and asks for
them by name — it never touches `GetCommandLineW` itself.

Once the host reports that its main-thread drain has actually fired, the mod
drives the main menu into an **offline** raid on that map. Zero clicks from
launch to deployed.

It prints one of three verdicts and never nothing:

```
AutoRaid CMDLINE VERDICT PASS          the client reported phase DEPLOYED
AutoRaid CMDLINE VERDICT FAIL          the flow refused; the line names the step
AutoRaid CMDLINE VERDICT INCONCLUSIVE  4 minutes passed, or the host could not
                                       be asked what phase it is in
```

`PASS` is the game's **own** deploy signal, not this mod reporting that its last
button press returned.

A refusal is not retried. In particular "the client is already in a raid" is
terminal: driving the main menu from inside a raid presses into a UI that is not
there.

### 2. A map menu on a key

Turn on `hotkeys` and press `menuKey` (default `F8`) at the main menu.

```
      AutoRaid -- choose a map
   1.  Customs
   2.  Woods                <- highlighted
   3.  Shoreline
   ...
      state: WAIT-MENU
```

* **Up / Down** or **1–9** — choose
* **Enter** — enter that raid
* **Escape** or **menuKey** — close

The answer to Enter is shown in the menu for five seconds and logged. If the map
is not currently on offer the refusal **names every map that was**.

`enterKey` (default `None`, i.e. off) skips the menu entirely and enters
`defaultMap`. It keeps working even where the overlay cannot be drawn — arming a
raid does not need anything on screen.

If the menu cannot be drawn (an older host, an ABI mismatch, or the host has not
armed its shared region) the mod says so **once**:

```
AutoRaid MENU: INCONCLUSIVE -- <why>
```

and `enterKey` still works. It never fails silently.

### 3. A spawned default loadout

`loadoutMode` is `current` as shipped, which means **this mod does nothing at all
to your gear** and `loadout.json` is not even opened.

Set it to `spawned` and, for each raid:

1. the gear the character was wearing is moved to the **stash** — never
   destroyed, and the operation refuses with a verdict if it cannot be done;
2. the kit in `loadout.json` is **created** and equipped;
3. every created item is **stripped from the profile at match end**, so none of
   it can ever reach the stash — whether you extract, die or disconnect.

The verdict comes from the backend and is logged verbatim:

```
AutoRaid LOADOUT VERDICT PASS -- profile <id>, requested 11, minted 11, placed 11, rejected 0
```

`/aowlspt/autoraid/status` serves the same information as JSON.

---

## The command line

| token | what it does | default |
|---|---|---|
| `-aowl.raid=<MapLabel>` | enter an offline raid on this map at launch | absent = do nothing |
| `-aowl.raidside=pmc\|scav` | which side to choose | `pmc` |

The **map label is the map's displayed name on the location screen**, matched
case-insensitively. That displayed text is the only thing that identifies a map
on this build: every tile GameObject is called `Location Template(Clone)`.

Quote a label with a space: `--raid="Ground Zero"`.

A bare `-aowl.raid` with no value arms **nothing**. There is no default map worth
guessing at, and entering the wrong raid is worse than entering none.

---

## Settings

All seven live in `config.json` beside the DLL, and in the F12 panel / the native
MODS tab.

| key | default | applies |
|---|---|---|
| `hotkeys` | `false` | live |
| `menuKey` | `"F8"` | live |
| `enterKey` | `"None"` | live |
| `defaultMap` | `"Woods"` | live |
| `maps` | twelve labels | live |
| `loadoutMode` | `"current"` | next raid |
| `applyAt` | `"auto"` | restart |

`hotkeys` is **the gate**. With it off, nothing is polled — not
`GetModuleHandle`, not `UnityEngine.Input::GetKeyDown` — and the two key rows
provably do nothing. It is itself flagged as a keybind row so that a
keybinds-only view cannot show you a key while hiding the switch that makes it
fire.

`menuKey` / `enterKey` take a `UnityEngine.KeyCode` **name** (`F8`, `F9`, `Home`,
`Insert`, `BackQuote`, …). A name the game does not know resolves to UNBOUND and
**says so in the log** — it never silently becomes "never fires".

`maps` is the list the **menu** offers, which is not the list the game is
offering right now. The location screen shows only what the current mode allows
(measured 2026-09-02: Reserve, Lighthouse, Interchange, Customs, Ground Zero,
Icebreaker, Woods — seven of the twelve listed here).

---

## `loadout.json`

Only read when `loadoutMode` is `spawned`. The shape is
`mods/tarkov/emu/loadout.nim`'s, unchanged, so this file is exactly what
`/aowlspt/tarkov/autoscript/loadout` already accepts:

```json
{
  "clear": false,
  "gear": [
    { "query": "AK-74N", "slot": "FirstPrimaryWeapon",
      "magazine": "6L20 30-round magazine",
      "ammo": "56dff061d2720bb5668b4567", "condition": 100 },
    { "tpl": "5648a7494bdc2d9d488b4583", "slot": "ArmorVest" },
    { "query": "Salewa first aid kit", "inside": "TacticalVest", "count": 2 },
    { "query": "6L20 30-round magazine", "inside": "Backpack", "count": 2 }
  ]
}
```

* `query` — an item's English name, matched as a **case-insensitive substring**
* `tpl` — a 24-hex template id
* `slot` — worn in that equipment slot
* `inside` — placed in that worn container's grid
* neither — the stash · both — **refused by name**, rather than one silently
  winning

### Ambiguity is refused, not resolved

A `query` that matches **more than one** item is refused with the list, because
"the first match" is an arbitrary document order and a loadout that silently
equips the wrong rifle is a test whose result means nothing.

Every query and id in the shipped file was checked on 2026-09-04 against
`db.json` with the same matching rule the server uses. **Four entries carry a
`tpl` instead of a `query` because the name is genuinely ambiguous**, and they
are named here so nobody "simplifies" them back:

| wanted | why it is an id |
|---|---|
| `5.45x39mm BT gs` | also matches three ammo packs |
| `PACA Soft Armor` | also matches the Rivals Edition |
| `9x18mm PM PS gs PPO` | also matches two ammo packs |
| `PM 9x18PM 90-93 8-round magazine` | **two template ids share that exact name** |

### The shipped default loadout

A deliberately cheap, common PMC kit — a default that hands out end-game armour
makes every test meaningless.

* **AK-74N** with a loaded 6L20 magazine (BT gs), two spares in the backpack
* **Makarov PM** with its 8-round magazine (PS gs PPO)
* **Kiba Arms Tactical Tomahawk** in the scabbard
* **ZSh-1-2M helmet**, **PACA Soft Armor**
* **Scav Vest** — six 1×1 cells, so the grid-placement step is actually
  exercised rather than always succeeding into a huge container
* **WARTECH Berkut BB-102** backpack
* 2× Salewa, 2× Aseptic bandage, 1× Immobilizing splint, in the rig

---

## What this mod does not do

* **It installs no detour.** Not one. Two detours on one function have the second
  overwrite the first's trampoline and silently kill the first feature.
* **It resolves no IL2CPP name.** Every call goes to an RVA byte-verified against
  the sixteen bytes it is declared to begin with.
* **It writes nothing into game memory.** Every state change is a call to the
  method the game itself calls.
* **It enumerates no scene roots.** Every screen comes from its own `::Show`
  receiver; every root is reached by climbing from one.
* **It touches nothing after READY.** Once the accept screen advances the raid is
  loading, and touching the UI during that load errors matchmaking.

---

## Building

```powershell
python tools\buildlock.py build mod autoraid
```

## Reading a run

```powershell
python tools\hostlog.py summary
```

Grep for `AutoRaid`. A run that reaches a raid shows the `READBACK` lines in
order. A run that does not shows exactly **one** refusal naming the step, the
operation ("crumb"), and a census of what was actually ACTIVE on screen — read
that line, not the screen.

`docs/AUTORAID-MAP.md` has the three flows with the evidence behind every claim,
and a list of what has **not** been verified live.
