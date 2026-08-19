# aowl.blackdivision

A hostile PMC faction — six roles, their own names, gear, difficulty and
spawn behaviour — ported from **WTT Black Division** by TacticalToaster /
Matthew Ryan Christensen II. Upstream is MIT; the licence travels with the port
and its text is in `LICENSE` beside this file.

```
aowl build-mod mods/blackdivision
aowl run mods/blackdivision            # the simulator self-test
```

Depends on `mods/morebots`, which does the database writing on this mod's
behalf. Without it this mod registers nothing and says so after three seconds.

## Read this first

**Nothing here has ever run against BSG's client.** The server half is data and
is checkable offline, and `aowl run` checks it. The client half is a read-only
watch whose every `EFT.` name is from the pre-1.0 C# surface and is a hypothesis
until a runtime answers it.

## What the original did, feature by feature — and where this port stands

| # | Upstream feature | Status here |
|---|---|---|
| 1 | Six custom bot types (lead, assault, breacher, support, Wedge, raider — `blackDivIb`) with ids 848420, 848421, 848422, 848423, 848424 and 848426 | **Implemented.** All six registered through `morebots.type.register`. 848425 is deliberately skipped, following upstream. |
| 2 | Two bot templates — one shared by five roles, one for Wedge — with appearance, health, skills, difficulty and loot generation | **Implemented, upstream's data verbatim.** 60KB and 59KB. 141 first names + Wedge. |
| 3 | Per-role loadouts | **Implemented, and this port ships more than upstream did.** See below. |
| 4 | Hostility: Black Division against scavs, rogues, USEC, BEAR, infected, RUAF, and each of those against it | **Implemented,** as `ENEMY_BOT_TYPES` edits in all four difficulty blocks, both directions, switchable per faction group in `config.json`. RUAF is the exception and always was: that faction belongs to TacticalToaster's other mod, so the relation is sent marked `optional` and morebots reports the miss at info with the consequence rather than warning about a thing nobody can fix. |
| 5 | Revenge — a bot that sees a squadmate die hunts the killer | **Implemented** (`REVENGE_BOT_TYPES`). |
| 6 | Spawn tables: a roaming hunt squad on ten maps at a randomised, low-biased point in the raid | **Implemented,** and the record shape is now correct — see "What was broken". |
| 7 | The Labs event — Wedge with 3–6 raiders in the three interior zones | **Implemented.** |
| 8 | The two Labs extract ambushes, independently rolled | **Implemented,** now breacher-led. |
| 9 | Re-roll every spawn at the end of each raid | **Implemented,** off `tarkov.raid.ended` rather than a `/client/match/local/end` router. |
| 10 | Locale string so the kill feed says "Black Div." | **Implemented** (one key — that is genuinely all upstream has). |
| 11 | Three hidden kill-count achievements (4/12/50 operators) | **Implemented and actually loaded.** Upstream ships the data and never loads it; the call is commented out in its `Mod.cs`. |
| 12 | WTT-Armory alternate assault loadout, detected by mod GUID | **Partly.** The loadout ships; GUID detection does not exist in this plugin API, so it is a config switch. |
| 13 | CS-gas grenades for Wedge and the raiders, detected by mod GUID | **Partly,** same reason. |
| 14 | `WTT-ServerCommonLib`'s three services (loadout overlay, locale injector, achievement loader) | **Implemented,** each turned out to be one `dbWrite`. |
| 15 | `WTT-ContentBackport`'s item and appearance templates | **Not shipped — content, not code.** 18 loadout ids and all 4 bodies, 4 feet and 2 voices are its. Consequences below. |
| 16 | **Prepatcher:** append six members to `EFT.WildSpawnType` in `Assembly-CSharp.dll` with Mono.Cecil | **Impossible post-1.0.** IL2CPP: no managed assembly, the enum is native constants with switch tables already compiled, no pre-load window. |
| 17 | **`HuntTargetLayer`** at priority 10 over the PMC brains, `AdvAssaultTarget` removed, `HuntManager.AddHuntRoles`/`AddHuntSides` | **Impossible post-1.0.** BigBrain custom layers and Unity `MonoBehaviour`s hosted by BepInEx; none of the three exists. The *timing and placement* half of the hunt survives, because that lives in the spawn table. |
| 18 | **`BDNvgPatch`** — suppress night vision for BD bots | **Impossible, and already dead upstream.** `BotOwner_0` was removed in SPT 4.1.2 so it could no longer tell which bot it was looking at; the shipped version returns unconditionally. A hook here is told a method's declared arguments and not `this`, so the only expressible version would suppress NVG for *every* bot in the raid. |

## What this port ships that upstream did not

**Three roles had no loadout at all.** `blackDivLead`, `blackDivBreacher` and
`blackDivSupport` shared a template whose `inventory.equipment` is empty by
design — every gun and plate comes from the overlay — and upstream ships an
overlay for only three of the six. The other three spawned **naked**: no weapon,
no armour, no helmet. They still spawned, still had names, still counted as
Black Division, and so the faction was half of what its own role list claimed.

They now have loadouts, built role-appropriately and **verified against a real
SPT 4.x item table**:

| role | weapons | equipment ids | mod roots / refs | calibers / rounds |
|---|---|---|---|---|
| `blackDivLead` | DMRs and battle rifles — SR-25, G28, RFB, SA58, SCAR-H, MDR, M700 | 75 | 105 / 360 | 4 / 14 |
| `blackDivBreacher` | shotguns and SMGs — M870, 590A1, AA-12, M3 Super 90, Vector, MP5, UMP, MP9-N, MP7, P90, MPX | 80 | 120 / 429 | 5 / 22 |
| `blackDivSupport` | belt-fed and high-capacity — M60E6, G36, AUG A3, Mutant, AK-101, SCAR-H, plus a 40mm launcher as a second primary | 76 | 135 / 500 | 7 / 27 |

**Mixed squads.** Every hunt squad upstream spawns is led by `blackDivAssault`
with `blackDivAssault` escorts. So even with loadouts, four of the six roles
would never have appeared in a raid. Squads are now mixed — lead 45%, assault
30%, support 15%, breacher the rest — and the escort is never the leader's role.

**Per-feature configuration.** `spawns.enabled`, `spawns.labsEvent`,
`spawns.labsGateAmbushes`, `spawns.showOnMap` and six `hostility.*` switches,
every key documented in `config.json` itself. Turning `spawns` off also
*removes* this mod's previous records, because the database persists and a
switch that only stops adding is a switch that does not work.

## What was broken, and is not any more

**Four of seventeen `BossLocationSpawn` field names were wrong.** This is the
headline correctness fix and it is worth stating plainly, because it is the
exact failure this pass was looking for. `bd/spawns.nim` wrote:

```
BossDifficulty   BossEscortDifficulty   IsBossPlayer   IsRandomTimeSpawn
```

All four spellings are plausible, readable and wrong. A real SPT 4.x database
has 140 `BossLocationSpawn` records and **140 of 140** spell them:

```
BossDifficult    BossEscortDifficult    BossPlayer     RandomTimeSpawn
```

A record with the wrong spelling deserialises with those four members at their
type defaults. Nothing errors. Nothing logs. The mod looks installed and the
squad does not arrive, or arrives wrong, and the symptom is indistinguishable
from never having reached that map. `ShowOnTarkovMap` / `ShowOnTarkovMapPvE`
(on 135 of 140) and `DependKarma` / `DependKarmaPVE` were missing entirely and
are now written.

**A hunt map that cannot host a spawn is refused, not written to.** The check
used to be "is `locations.<map>.base` in the database", and that is not the
question. A stock SPT 4.x database carries four location slots — `suburbs`,
`terminal`, `town`, `privatearea` — that are records with no map behind them:
they have fields, so they pass any "is it there" probe, and they have
`SpawnPointParams: []`. Put one in `huntMaps` and this mod wrote a perfectly
well-formed `BossLocationSpawn` entry onto a slot with nowhere to put a bot.
Nothing errors, nothing logs, and the squad simply never exists.

It is not hypothetical. `mods/icebreaker` rebinds exactly the `suburbs` slot,
and it rebinds it *without* `SpawnPointParams`, which it refuses to invent
because a spawn point is nothing but world coordinates and a guessed one puts
the player inside the hull. So the slot becomes a real map with a name, a cap,
waves and exits, and it still cannot host a spawn — and adding it to `huntMaps`
is a reasonable thing for a player to try.

The test is `SpawnPointParams` and not a list of map names: it is the property
that actually decides the question, and the day somebody drops a spawn-point
array in, this starts working with no code change. **Present and empty is the
refusal; absent is not** — a partial database dump carries no `SpawnPointParams`
anywhere, and reading a refusal into silence would mean writing nothing at all
on a database that is merely incomplete. The self-test reports both branches.

## What it still cannot do, and why

* **A map whose `SpawnPointParams` is empty gets no squad**, and is named at
  boot with the reason. The only fix is that map's own spawn points; there is
  nothing this mod can write instead.
* **A custom `WildSpawnType` cannot reach the client.** The six role ids stay
  server-side, where the difficulty documents and the faction graph are written
  in them. The client half identifies the squad by this mod's own nickname
  table instead, and says so.
* **The hunt behaviour is timing and placement only.** Once a squad spawns it
  behaves like the PMC brain it borrows. Nothing tracks the player.
* ~~**The emulator does not read loadouts.**~~ **It does now**, and this claim
  was true when written: the generator read `firstName`, `health.BodyParts[0]`
  and the first entry of each `appearance` list, so every bot in every raid
  carried an empty container and an empty stash while 322 equipment ids and
  2,122 mod references sat in the database untouched. `mods/tarkov/emu/bots.nim`
  now builds the loadout from `inventory.equipment` (a weight map per slot, not
  a list), `chances.equipment`/`chances.weaponMods`/`chances.equipmentMods`, and
  the ammo tables. Three details in there were guessed wrong first and are
  worth knowing if this mod's data ever stops arriving: the chance tables are
  three, not one `chances.mods`; a mod slot name appears in **either casing** in
  stock data, so an exact-key lookup silently misses; and a weight of zero means
  never, so a pool summing to zero must produce nothing rather than element
  zero — which is how every scav on a map ends up in the same hat.
  They are still written, because the database is what a *real* SPT server and
  any future generator read, and because writing them wrong would be a bug that
  only surfaced later. **This is a gap in `mods/tarkov`, not in this mod**, and
  it is the single change that would make this faction's gear real.
* **Appearance is broken without WTT-ContentBackport.** The emulator takes
  `appearance.body[0]` etc. verbatim, and index 0 of every list here is a WTT
  id. Without that mod the bots get a customisation id that resolves to nothing.
* **`armoryLoadouts` without WTT-Armory gives unarmed bots.** All eleven weapon
  ids in that loadout -- seven primaries and four holsters -- are Armory's, so
  there is nothing left to fall back on. The self-test names them.
* **No night-vision control, no per-bot Harmony behaviour.** See rows 16–18.

## The self-test

`aowl run mods/blackdivision` checks the data rather than reporting that it
parsed, because a faction that is silently three quarters there still spawns and
nothing looks wrong. It reports counts:

`file(s)` counts the files the self-test actually parsed — the two distinct
templates, the six role loadouts, the Armory loadout and the achievements — not
everything under `data/`; the locales and the per-role config blocks are read
elsewhere.

```
data: 10 file(s): 322 equipment id(s) across 58 slot(s),
      642 mod root(s) with 2122 reference(s), 91 round(s) in 34 caliber(s),
      56 equipment chance(s), 142 name(s)
```

and checks, per `bd/validate.nim`:

* every template id is 24 lower-case hex digits (case is not folded — the item
  table is keyed lower-case and an upper-case paste looks identical in a diff);
* every equipment slot is one of the fourteen the game has;
* every mod slot is `mod_*`, `patron_in_weapon*`, `camora_*` or a named armour
  sub-slot **in either casing**, because a stock database genuinely contains
  both (`Helmet_top` on 59 items, `helmet_top` on 3 — and `soft_armor_right` on
  47 with `Soft_armor_right` on none at all);
* every pool has a total weight that can actually roll — a pool of entries all
  weighted 0 is an empty slot with contents in it;
* every pool has a chance in this file or in the template it lands on;
* every caliber has at least one round;
* `appearance.{head,body,feet,hands}` and `health.BodyParts[0]` are non-empty,
  because those are the only parts of a template the emulator reads;
* no duplicate role id, role name, first name or achievement id;
* every achievement has a locale string;
* every configured hunt map that this database has can actually host a spawn,
  with the ones that cannot named — both branches are exercised, so the guard
  is tested rather than described.

It also drives the whole `morebots.ready` handshake with no backend, exercises
the client watch's Win64 hidden-pointer rule exhaustively, and prints the
binding report offline. `selfTestRuntime` in `config.json` points it at a
`GameAssembly.dll` for a real binding answer without the game running.
