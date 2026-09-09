# Bot AI — Squad-Shared Objectives (design, ready to build)

Status: **DESIGN COMPLETE, build gated on the SAIN driver actuating live** (fact
#227 — the driver still does not move bots; vanilla AI drives them today with
`sain.enabled=false`). Phases 0–2 need NO new RVAs and NO by-name hazards, but
their live verification needs the client running with a human present.

## What already exists (build, don't rebuild)
ORBIT is an objective system in all but name. Its objectives are just
spawn-density cells, its squad is fake (server "leader" = lowest census bot id),
it has no loot/quest types.
- **Server** `mods/tarkov/emu/orbit.nim` + `mods/sain/server/dispatch.nim`:
  `buildPlan` scores map cells → anchors; `emitPlan` broadcasts
  `tarkov.orbit.plan` once/raid; `dispatch.nim` assigns anchors, leash/splinter,
  actuates over botnav → `EFT.BotOwner::GoToPoint` (kind=15 RVA 0x81CB40).
- **Client** `mods/sain/client/bridge.nim` + `core/decide.nim`: reads bots (fact
  #226), 10Hz cascade self>combat>squad, `moveTargetFor` → `mvGoTo`
  (`Mover.GoToPoint`). **The real squad lives ONLY here**: `groupKeyOf` reads
  `BotOwner.BotsGroup` as a bare pointer via a MEASURED getter (not by-name);
  `core/squad.nim` partitions by that pointer.

Central facts: the census channel carries **no group id** (so squad identity is
client-only), and there are **two GoToPoint actuators** (client per-decide,
server per-census) racing last-writer-wins. Reconciling to ONE writer is the spine.

## Model (`mods/sain/core/objective.nim`, new)
`kind`: okReposition | okLoot | okQuestPoi | okHold | okHunt.
`target`: Vec3 (+ optional entityKey uint64). `priority`: float vs `urgency()`.
`assignment`: squadKey (the groupKey pointer) + per-member role omConverge /
omCover / omStagger (one shared objective → different destination per member).
`completion`: reached-within-reach | timeout | invalidated.
**Cascade slot**: a NEW lowest layer below squad ("idle intent"), reached only
when not fighting (nav commands are ignored mid-fight anyway). Add
`objectiveLayer` + a `cdMoveToObjective` case so client `decide` becomes the
SINGLE destination chooser (resolves the two-actuator race).

## Split (recommended)
- **Backend = objective catalog** (data only, sees db.json/waypoints, never live
  groups). Extend buildPlan/emitPlan → `tarkov.objectives.catalog` superset:
  reposition anchors + **waypoints points as okQuestPoi** (real coords; db.json
  staticContainers are all (0,0,0) — dead).
- **Client = assigner + actuator**. MOVE leader/splinter/leash logic out of
  server dispatch (its leader is fiction) into client `objective.nim`,
  partitioning by the REAL groupKey. Leader picks squad objective from catalog
  (reuse pickAnchor, seed by squad key); members derive per-role destination
  (converge on point / stagger via flank.nim spread / cover overwatch); leash to
  leader past leashM. **Retire/gate the server GoToPoint path** → one writer.

## Loot (honest capability)
- Move-to-loot: feasible now (position through mvGoTo).
- Real looting (open container, transfer): NOT feasible without NEW measured
  RVAs (LootableContainer.Interact/owner + inventory move) — none in
  docs/SAIN_RVA.md. Phase 3, RVA-gated, never by-name.
- Loot position source: static containers are (0,0,0) dead → use **live corpses**
  (driver already tracks every bot's last position) and waypoints POIs.

## Quest POIs
Best source = **waypoints** (`mods/waypoints/data/<map>.json`, ~8556 real
world-metre points over 10 maps, served at /waypoints/points), NOT db.json.
Merge as okQuestPoi anchors with higher priority. Pure data plumbing, no binding.

## Config (`mods/sain/config.json`, flat keys, Bot-AI-named)
`objectivesEnabled`; per-kind `seekLoot`/`seekQuestPoi`/`holdPositions`/
`huntLastKnown`; `squadShareObjectives`, `objectiveLeashM`/`Splinter M`/`ReachM`/
`HoldMs` (reuse ORBIT semantics); `lootSeekAggressiveness` (feeds wantsAnchor).
`_`-prefixed help must state real looting is move-and-loiter until the RVA lands
(no render-but-does-nothing toggles).

## Phasing
- **P0** catalog generalization (backend, data only, safe): orbit.nim +
  waypoints.nim + tarkov.nim.
- **P1** client squad assignment + move-to-objective (safe, existing mvGoTo RVA;
  retire server GoToPoint): objective.nim(new) + decide.nim + squad.nim +
  bridge.nim + dispatch.nim(gate) + config.json. **Delivers squads sharing one
  objective.**
- **P2** bodies-as-loot / hunt from the live corpse table (safe, no RVA).
- **P3 (deferred, RVA-gated)** real container looting: measure interaction +
  inventory-move RVAs into docs/SAIN_RVA.md first.

## Verification (falsifiable, per phase)
- P0: catalog has ≥1 okQuestPoi from waypoints with non-zero spread (falsifier:
  all-reposition or all-origin).
- **P1 core claim (squad convergence)**: in /sain/status, group live bots by
  groupKey; every member's resolved moveTo within splinterM of ONE catalog
  position per group, and distinct groups → distinct positions. Falsifier: one
  group's members >splinterM apart, or all groups collapse to one point.
- P1 liveness: reuse gProgressed — ≥1 bot closes distance on its objective.
- P2: moveTo latches a known corpse position, navStatus != 2.
- P3: bot inventory item-count actually changes after interaction.

## Hazards
FATAL by-name: enumerating BotsGroup members (use the pointer-equality groupKey
getter). Backend must never attempt group identity. Phase-3 loot RVAs unmeasured.
`GoToByWay(Vector3[])` named in botnav header but unbound (optional, follow routes).

**PREREQUISITE: the SAIN driver must actuate bots live first (fact #227).**
Objectives cannot express themselves on a driver that doesn't move bots. Sequence:
driver RVA actuation (live-tested, human-confirmed) → then P0–P2 objectives.
