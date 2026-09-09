# SPT 4.1.5 bot control -- the measured map and the design

Goal (user, 2026-09-07): take full control of bot spawn points, spawn times,
who and what spawns, and what they spawn with, on **stock SPT 4.1.5 with SAIN**,
driven by the SAME backend brain (`aowlspt-backend.exe`, mods/basement) that
already plants people and loot into aowlspt's emulator -- no second backend.

Everything labelled MEASURED below was read out of the installed assemblies on
2026-09-07 with Mono.Cecil (`mods/basement/spt/MemberCheck`, plus a scratch
copy with extra verbs -- see section 6). Nothing in this document has run in a
live SPT client or server yet; section 5 lists exactly what is unproven.

Assemblies measured (copies taken to %TEMP% first, the live ones are locked):

| what | path | version |
|---|---|---|
| SPT server core | `D:\SPT415\SPT_Runtime\SPTarkov.Server.Core.dll` (+ `.DI`, `.Common`, `.Reflection`) | 4.1.5.0 |
| game client | `D:\SPT415\EscapeFromTarkov_Data\Managed\Assembly-CSharp.dll` | build the 4.1.5 client ships |
| SAIN | `D:\SPT415\BepInEx\plugins\SAIN\SAIN.dll` | `[BepInPlugin(me.sol.sain, SAIN, 4.5.1)]`, depends on `xyz.drakia.bigbrain 1.5.0` |
| BigBrain | `D:\SPT415\BepInEx\plugins\DrakiaXYZ-BigBrain.dll` | `[BepInPlugin(xyz.drakia.bigbrain, 1.5.0)]` |
| SAIN server mod | `D:\SPT415\SPT_Runtime\user\mods\Solarint-SAIN-ServerMod\{SAINServerMod,SAIN.ServerInterop,SAIN.Preset.Shared}.dll` | refs Server.Core 4.1.3 |
| reference mods on this install | `user\mods\acidphantasm-botplacementsystem`, `user\mods\MoreBotsServer`, `user\mods\BotCallsigns`, `plugins\MoreBotsAPI\MoreBotsPlugin.dll` | 4.1.x |

---

## 0. Status at a glance

| piece | state |
|---|---|
| Server-side hook map (bot generate, waves, loadouts) | MEASURED, section 1a-1c |
| Client spawner map (BotSpawner / scenarios / zones) | MEASURED, section 1b |
| SAIN external surface | MEASURED, section 1d: **no order API**; control = BigBrain layer above SAIN's |
| `mods/basement/spt/Basement.Server` (SPT server mod, C#) | BUILT: `dotnet build` 0 errors 0 warnings; 4 Harmony patches + status route; NOT installed, NOT run |
| `Basement.Client` `group.spawn` executor + `npc.*` BigBrain layer | BUILT: 0 errors (3 pre-existing warnings elsewhere in the project); NOT run |
| backend routes `/aowlspt/basement/spt/bots`, `/spt/waves` | NOT written -- patch block in section 4 for the coordinator |

---

## 1. The measured map

### 1a. Server: `/client/game/bot/generate`

Call chain, all MEASURED from IL (`callers` / `calls` verbs):

```
BotStaticRouter..ctor                registers "/client/game/bot/generate"  (ldstr in the ctor)
  -> RouteAction<GenerateBotsRequestData>(url, Func<string, T, MongoId, string, CancellationToken, ValueTask<string>>)
BotCallbacks.GenerateBots(string url, GenerateBotsRequestData info, MongoId sessionID) : ValueTask<string>
  -> BotController.Generate(MongoId sessionId, GenerateBotsRequestData request) : Task<IEnumerable<BotBase>>
  -> HttpResponseUtil.GetBody<IEnumerable<BotBase>>(data, BackendErrorCodes, string, bool)
BotController.Generate
  -> ProfileHelper.GetPmcProfile(sessionId)
  -> BotController.GenerateBotWaves(sessionId, request, pmcProfile)          [protected]
       -> BotController.GetMostRecentRaidSettings(sessionId)                 [protected]
       -> per GenerateCondition: GetBotGenerationDetailsForWave(condition, pmcProfile, allPmcsHaveSameNameAsPlayer, raidSettings)
       -> BotController.GenerateBotWave(sessionId, condition, details)       [protected, IEnumerable<BotBase>]
            -> BotController.TryGenerateSingleBot(sessionId, details, botIndex)
                 -> ICloner.Clone<BotGenerationDetails>
                 -> BotGenerator.PrepareAndGenerateBot(sessionId, details) : BotBase      [public]
                      -> BotHelper.GetBotTemplate(role) ; ICloner.Clone<BotType>
                      -> BotGenerator.GenerateBot(sessionId, bot, botJsonTemplate, details)  [protected]
                           BotLevelGenerator.GenerateBotLevel(...)
                           BotNameService.GenerateUniqueBotNickname(botJsonTemplate, details, uniqueRoles)
                           Info.set_Nickname / set_LowerNickname ; Info.set_Level/Experience
                           BotGenerator.SetBotAppearance(...)
                           BotInventoryGenerator.GenerateInventory(botId, sessionId, botJsonTemplate, details) -> BotBase.set_Inventory
                           BotGenerator.GenerateInventoryId(bot) ; BotInfoSettings.set_Role
                 -> MatchBotDetailsCacheService (caches the bot for the match)
```

Request/response models (MEASURED properties):

* `GenerateBotsRequestData { List<GenerateCondition> Conditions }`,
  `GenerateCondition { string Role; int Limit; string Difficulty }` -- the
  client sends exactly this from `EFT.ClientBackendSession/CG_LoadBots`
  (`ldstr "/client/game/bot/generate"`, wraps `BotGenerateRequestParams`).
* `BotGenerationDetails { bool IsPmc; string Role, RoleLowercase, Side; int? PlayerLevel;
  string PlayerName; MinMax<int> LocationSpecificPmcLevelOverride; int BotRelativeLevelDeltaMax/Min;
  int BotCountToGenerate; string BotDifficulty; bool IsPlayerScav; string EventRole;
  bool AllPmcsHaveSameNameAsPlayer; string Location; bool ClearBotContainerCacheAfterGeneration;
  int BotLevel; string GameVersion }`.
* `BotBase { Info, Customization, Health, Inventory, Skills, ... }`;
  `Info { Nickname, MainProfileNickname, LowerNickname, Side, Level, GroupId, TeamId, BotInfoSettings Settings, ... }`;
  `BotInfoSettings { Role, BotDifficulty, Experience, StandingForKill, AggressorBonus, UseSimpleAnimator }`.
  `PmcData : BotBase`.
* The raid a session is in: `ProfileActivityService.GetProfileActivityRaidData(MongoId) : ProfileActivityRaidData
  { GetRaidConfigurationRequestData RaidConfiguration; RaidChanges RaidAdjustments; LocationTransit LocationTransit }`;
  `GetRaidConfigurationRequestData : RaidSettings { Location, TimeVariant, Side, RaidMode, BotSettings, WavesSettings, ... }`.

**How a mod can intercept -- MEASURED and the whole reason the design is what it is:**

* **No method on `BotController`, `BotGenerator`, `BotInventoryGenerator`,
  `BotNameService`, `LocationLifecycleService`, `PmcWaveGenerator` or
  `CustomLocationWaveService` is virtual** on 4.1.5 (`virt` verb: none prints
  `virtual`/`override`; only `Router.GetHandledRoutes` is virtual). Subclass-and-
  override through DI is therefore impossible for the bot pipeline.
* DI: every service is `[SPTarkov.DI.Annotations.Injectable(InjectionType, int TypePriority)]`
  (`InjectionType { HostedService=0, Singleton=1, Transient=2, Scoped=3 }`; the
  ctor defaults are `(Transient, int.MaxValue)`). `DependencyInjectionHandler`
  scans mod assemblies (`AddInjectableTypesFromAssembly`).
* The override mechanism SPT ships for servers is **Harmony through
  `SPTarkov.Reflection.Patching.AbstractPatch`**: `protected virtual MethodBase GetTargetMethod()`,
  static methods tagged `[PatchPrefix] / [PatchPostfix] / [PatchTranspiler] / [PatchFinalizer] / [PatchIlManipulator] / [PatchReverse]`,
  `Enable()/Disable()`, ctor `AbstractPatch(string name)`. `PatchManager
  { AddPatch, AddPatches, EnablePatches, DisablePatches }` is `[Injectable]`.
  acidphantasm-botplacementsystem on this install does exactly this:
  `AdjustWavesPatch : AbstractPatch` with `[Injectable]`, target
  `AccessTools.Method(typeof(RaidTimeAdjustmentService), "AdjustWaves")`,
  `static bool Prefix(LocationBase mapBase, RaidChanges raidAdjustments)`; its
  `PatchManager : IOnLoad` (`[Injectable(TypePriority = 100000)]`) takes
  `IEnumerable<IRuntimePatch>` by ctor injection and calls `Enable()` on each.
* Mod lifecycle: `IOnLoad { Task OnLoadAsync(CancellationToken) }`;
  `OnLoadOrder` constants `Watermark=0, Preload=100000, GameCallbacks=200000,
  TraderRegistration=300000, Routers=400000, ... PostLoad=1000000`. MoreBotsServer's
  entry runs at `TypePriority = 1000005`.
* Metadata: `IModMetadata { ModGuid, Name, Author, Contributors, Version(SemanticVersioning.Version),
  SptVersion(SemanticVersioning.Range), HasPrepatcher, Incompatibilities, ModDependencies, Url, License }`.
  (The EFMB scaffold's `IsBundleMod` is not on 4.1.5's interface.)
  `SemanticVersioning.Version(string, bool loose)`, `Range(string, bool loose)`.
* Custom routes: subclass `StaticRouter(JsonUtil, IEnumerable<RouteAction>)`
  with `[Injectable]`; `RouteAction<T>(string url, Func<string, T, MongoId, string, CancellationToken, ValueTask<string>>)`;
  body helpers `HttpResponseUtil.GetBody<T>(T, BackendErrorCodes, string, bool)` / `NoBody<T>(T)`;
  `JsonUtil.Serialize<T>(T, bool indented)` / `Deserialize<T>(string)`.
  `EmptyRequestData` is `SPTarkov.Server.Core.Models.Eft.Common.EmptyRequestData`.
* Mod folder: `ModHelper.GetAbsolutePathToModFolder(Assembly)`, `GetJsonDataFromFile<T>(path, file)`.
* Logging: `SPTarkov.Common.Models.Logging.ISptLogger<T> { Success/Error/Warning/Info/Debug/Critical(string, Exception) }`.

Reference mod layout on disk (MEASURED): `SPT_Runtime\user\mods\<Name>\<Name>.dll` + data files; no manifest, the `IModMetadata` record is the manifest.

### 1b. Spawn points and waves

**Server side (what the client receives):**

* `POST /client/match/local/start` (ldstr in `MatchStaticRouter..ctor`) ->
  `LocationLifecycleService.StartLocalRaidAsync(MongoId, StartLocalRaidRequestData, CancellationToken)`
  -> `GenerateLocationAndLoot(sessionId, name, generateLoot) : LocationBase` (public) ->
  `AdjustBotHostilitySettings(loc)`, `AdjustExtracts(...)`, `BotNameService.ClearNameCache()`,
  `StartLocalRaidResponseData.set_ExcludedBosses(List<string>)`.
  `StartLocalRaidResponseData { ServerId, ServerSettings, Profile, LocationBase LocationLoot, TransitionType, Transition, ExcludedBosses }`.
* `GenerateLocationAndLoot` body: `LocationTable` -> `Location.Base` ->
  `ICloner.Clone<LocationBase>` -> `PmcWaveGenerator` -> `ProfileActivityService.GetProfileActivityRaidData(sessionId).RaidAdjustments`
  -> `RaidTimeAdjustmentService.MakeAdjustmentsToMap(RaidChanges, LocationBase)` (which calls
  the protected `AdjustWaves` / `AdjustPMCSpawns` that acidphantasm patches) -> `LocationLootGenerator`.
  **So a postfix on `GenerateLocationAndLoot` sees the final per-raid clone**; everything SPT does to waves has already happened.
* `LocationBase` (MEASURED props that matter): `string Id, Name; List<Wave> Waves; List<BossLocationSpawn> BossLocationSpawn;
  IEnumerable<SpawnPointParam> SpawnPointParams; string OpenZones; NonWaveGroupScenario NonWaveGroupScenario;
  int BotMax, BotStart; int? BotStop, BotSpawnCountStep, BotSpawnPeriodCheck, BotSpawnTimeOnMin/Max, BotSpawnTimeOffMin/Max, MaxBotPerZone, BotMaxPvE, ...`.
* `Wave { string BotPreset, BotSide, SpawnPoints /*zone name*/, SptId, OpenZones; bool? KeepZoneOnSpawn, IsPlayers;
  WildSpawnType? WildSpawnType; int? Number, SlotsMax, SlotsMin, TimeMax, TimeMin, ChanceGroup; HashSet<?> SpawnMode }`.
* `BossLocationSpawn { double? BossChance; string BossDifficulty, BossEscortAmount, BossEscortDifficulty, BossEscortType,
  BossName, BossZone, TriggerId, TriggerName, SptId; bool? IsBossPlayer, IsRandomTimeSpawn, ShowOnTarkovMap(PvE), ForceSpawn, IgnoreMaxBots;
  int? Time, Delay; ... Supports; SpawnMode }`.
* `SpawnPointParam { string Id, BotZoneName, Infiltration; Vector3? Position, Rotation; Categories; Sides; int? CorePointId; double? DelayToCanSpawnSec; ColliderParams }`
  -- the authoritative list of zone names for a map.
* Static edits (before the clone) exist too: `CustomLocationWaveService.AddBossWaveToMap(locationId, BossLocationSpawn)`,
  `AddNormalWaveToMap(locationId, Wave)`, `ClearBossWavesForMap`, `ClearNormalWavesForMap`, `ApplyWaveChangesToAllMaps`;
  `PmcWaveGenerator.AddPmcWaveToLocation(locationId, BossLocationSpawn)`. `LocationTable.GetLocation(string name)` /
  `GetDictionary()`; map keys are properties `Bigmap, Woods, Shoreline, Interchange, RezervBase, Lighthouse, TarkovStreets, Sandbox, SandboxHigh, Laboratory, Factory4Day, Factory4Night, Labyrinth, Terminal, Town, Suburbs, ...`.

**Client side (what turns that into bots):**

* `EFT.BotsController` (public): `Init(IBotGame, IBotCreator, BotZone[], ISpawnSystem, BotLocationModifier, bool botEnable, bool freeForAll, bool enableWaveControl, bool online, bool haveSectants, IPlayersCollection, string openZones, BotLocationEvents)`;
  `BotSpawner BotSpawner {get}`; `BotsList Bots` (field; `IEnumerable<BotOwner> BotOwners`, `Count`, `OnBotAdd/OnBotRemove`);
  `Task ActivateBotsByWave(SpawnWave)`, `void ActivateBotsByWave(BossLocationSpawn)`, `void ActivateBotsWithoutWave(int, IGetProfileData)`;
  `GetClosestZone(Vector3, out float)`, `ClosestBotToPoint(Vector3)`, `AddEnemyToAllGroups(...)`, `SetSettings(int maxCount, BotPreset[], BotWeaponScattering[])`,
  `DevelopmentTeleportBot(BotOwner, Vector3)`, `GetSpawner()`.
  Reached through `Comfort.Common.Singleton<IBotGame>.Instance.BotsController` (`IBotGame { BotsController, BossSpawnScenario, GameDateTime, Status, WeatherCurve }`; `Singleton<T> { static T Instance; static bool Instantiated }`) -- the path MoreBotsAPI's `HuntManager.InitRaid` uses (`Singleton`1.get_Instance -> IBotGame.get_BotsController -> BotsController.get_BotSpawner -> BotSpawner.add_OnBotCreated`).
* `EFT.BotSpawner` (abstract; `LocalBotSpawner`, `OnlineBotSpawner`), the actuators:
  * `Task SpawnBotByTypeForce(int count, WildSpawnType botType, BotDifficulty dif, BotSpawnParams spawnParams)` -- N bots of a role, zone chosen by the game.
  * `Task ActivateBotsWithoutWave(int count, IGetProfileData data)`; `void ActivateBotsByWave(BossLocationSpawn)`; `Task ActivateBotsByWave(SpawnWave)`.
  * `void SpawnBotsInZoneOnPositions(List<ISpawnPoint> openedPositions, BotZone botZone, BotCreationData data, Action<BotOwner> callback)` -- **bots at explicit points**.
  * `SimpleBotSpawnDelayModel TryToSpawnInZoneInner(BotZone, BotCreationData, int count, bool withCheckMinMax, bool newWave, List<ISpawnPoint> pointsToSpawn, bool forcedSpawn)`; `TryToSpawnInZoneAndDelay(...)`.
  * zones: `BotZone GetClosestZone(Vector3, out float)`, `GetZoneByName(string)`, `GetRandomBotZone(bool canBeSnipe)`, `GetPmcZones()`, `SpawnZones(bool)`.
  * events: `Action<BotOwner> OnBotCreated`, `OnBotRemoved`, `OnSpawnedWave`; `GetAllBotsNearTarget(Vector3, float)`, `ClosestBotToPoint`, `SetMaxBots(int)`, `CheckOnMax(...)`.
  * private state a caller needs: `IBotCreator _botCreator` (field), `BotsList _bots`, `BotZone[] _allBotZones/_openedZones`; `BotSpawner : ITokenGetter` (`GetCancelToken()`).
* `BotCreationData` (global namespace): `static Task<BotCreationData> Create(IGetProfileData, IBotCreator, int count, ITokenGetter)`,
  `static CreateWithoutProfile(IGetProfileData)`, `AddPosition(Vector3, int corePointId)`, `AddProfile(s)`, `Separate(int)`, `SpawnParams`, `Profiles`, `Count`, `Side`.
* `IGetProfileData` impls: `GetProfileDataParams(EPlayerSide side, WildSpawnType role, BotDifficulty botDifficulty, float spawnTime, BotSpawnParams spawnParams, bool keepZoneOnSpawn)`, `GetProfileDataSide(EPlayerSide)`, `LocalDebugProfileDataParams`, `ServerDebugProfileDataParams`.
  `BotSpawnParams { SpawnTriggerType TriggerType; ShallBeGroupParams ShallBeGroup }`, `ShallBeGroupParams(bool group, bool bossGroup, int groupCount)`.
* `IBotCreator { Task<Profile> GenerateProfile(BotCreationData, CancellationToken, bool withDelete); Task ActivateBot(BotCreationData, BotZone, bool shallBeGroup, Func<..> groupAction, Action<BotOwner> callback, CancellationToken); ... }`; the live impl is `BotCreatorClient`. `GenerateProfile` is what posts `/client/game/bot/generate` -- so ANY client-side spawn still passes through the server hook in 1a.
* `EFT.Game.Spawning.ISpawnPoint` (an interface a plugin may implement): `Id, Name, SpawnBlocked{set}, Position, Rotation, EPlayerSideMask Sides, ESpawnCategoryMask Categories, Infiltration, BotZoneName, IsSnipeZone, DelayToCanSpawnSec, NextBornTime{set}, CorePointId{set}, ISpawnPointCollider Collider; CalcMultiSpawnDelay(float, BotCreationData), Dispose(), IsNotCollidedArtillery(ArtilleryShellingControllerServer), IsInPlayersIndividualLimits(BotCreationData), IncreaseUsedPlayerSpawnsForNearestPlayer(BotCreationData)`.
  `EPlayerSideMask { None, Usec=1, Bear=2, Pmc=3, Savage=4, All=7 }`, `ESpawnCategoryMask { Player=1, Bot=2, Boss=4, Coop=8, Group=16, Opposite=32, BotPmc=64, All=71 }`.
* `BotZone` (global): `Vector3 CenterOfSpawnPoints; ISpawnPoint[] SpawnPoints; string NameZone, ShortName; int MaxPersons; bool SnipeZone, CanSpawnBoss; PatrolWay[] PatrolWays; static bool IsOnNavMesh(Vector3); HaveFreeSpace(int)`.
* Scenarios: `EFT.WavesSpawnScenario : MonoBehaviour { static Create(GameObject, WildSpawnWave[], Func<..>, Location); Init(WildSpawnWave[]); Task Run(EBotsSpawnMode); Stop() }`,
  `EFT.NonWavesSpawnScenario { static Create(AbstractGame, Location, BotsController); Run(); Update(); ImplementWaveSettings(WavesSettings) }`,
  `BossSpawnScenario` (global). `EBotsSpawnMode { Anyway, BeforeGameStarted, AfterGameStarted }`.
* Enums: `EFT.WildSpawnType` (assault=1, pmcBot=9, exUsec=24, sectantWarrior=20, bossKilla=6 ... pmcBEAR=51, pmcUSEC=52, infectedAssault=60 ...); `BotDifficulty { easy, normal, hard, impossible }` (global); `EFT.EPlayerSide { Usec=1, Bear=2, Savage=4 }`; `EFT.EBotState { NonActive, PreActive, Active, ActiveFail, Disposed }`.

### 1c. Loadouts (server bot inventory generation)

* `BotInventoryGenerator.GenerateInventory(MongoId botId, MongoId sessionId, BotType botJsonTemplate, BotGenerationDetails) : BotBaseInventory` --
  the single call site is `BotGenerator.GenerateBot` (MEASURED). Inside: `GenerateInventoryBase()`, `GenerateAndAddEquipmentToBot(botId, sessionId, BotTypeInventory, Chances, inventory, details, raidConfig)`,
  `GenerateAndAddWeaponsToBot(...)`, `BotLootGenerator`, `BotEquipmentModGenerator`, `BotEquipmentFilterService`, `BotWeaponGenerator`.
* Everything a kit is made of comes from the **template**: `BotType { Appearance BotAppearance; Chances BotChances; Dictionary BotDifficulty; Experience BotExperience;
  List FirstNames; IEnumerable LastNames; Generation BotGeneration; BotTypeHealth BotHealth; BotTypeInventory BotInventory; BotDbSkills BotSkills }`,
  looked up by role with `BotHelper.GetBotTemplate(string role) : BotType` (`BotTable { Dictionary Types; BotBase Base; CoreBot Core }`).
  `BotHelper.IsBotPmc/IsBotBoss/IsBotFollower/IsBotZombie(string)`, `GetPmcSideByRole(string|WildSpawnType)`.
* Therefore "spawn with X" = **swap the template argument** for the role whose template describes X, and let SPT build the tree. No item trees are authored by us, ever.
* Names: `BotNameService.GenerateUniqueBotNickname(BotType, BotGenerationDetails, HashSet<string> uniqueRoles)`, `AddRandomPmcNameToBotMainProfileNicknameProperty(BotBase)`, `ClearNameCache()` (called at raid start). The bot's name ends up in `Info.Nickname`, `Info.LowerNickname` (and `MainProfileNickname` for PMC chat).

### 1d. SAIN 4.5.1 -- external entry points

MEASURED public surface (`publics`/`virt` on SAIN.dll):

* `SAIN.Interop.SAINExternal` (static): `IgnoreHearing(BotOwner, bool, bool ignoreUnderFire, float duration)`, `GetPersonality(BotOwner) : string`,
  `ExtractBot(BotOwner)`, `GetExtractedBots(List)`, `GetExtractionInfos(List<ExtractionInfo>)`, `TrySetExfilForBot(BotOwner)`, `TimeSinceSenseEnemy(BotOwner)`,
  `IsPathTowardEnemy(NavMeshPath, BotOwner, float, float)`, `CanBotQuest(BotOwner, Vector3 questPosition, float dotThresh)`, `IsQuestTowardTarget(BotComponent, Vector3, float)`.
  `SAIN.Interop.SAINInterop` (internal mirror). **There is no "go here / hold / follow / attack" API.**
* `SAIN.Components.BotComponent : BotComponentBase : MonoBehaviour` -- obtained by `BotManagerComponent.Instance` then `Component.GetComponent<BotComponent>()` (body of `SAINExternal.GetBotComponent`).
  Public classes on it: `Decision (SAINDecisionClass: CurrentCombatDecision/CurrentSquadDecision/CurrentSelfDecision, ResetDecisions(bool))`,
  `Mover (SAINMoverClass: WalkToPoint(Vector3, bool mustHaveCompletePath, float reachDist, bool checkSameWay), RunToPoint(..., ESprintUrgency, ...), CrawlToPoint, GoToCoverPoint, Stop(), SetTargetMoveSpeed, SetTargetPose, CanGoToPoint(Vector3, out NavMeshPath, bool, float))`,
  `EnemyController (SAINEnemyController: GetEnemy(profileId, bool), CheckAddEnemy(IPlayer), RemoveEnemy(profileId), ChooseEnemy(), ClearEnemy(), IsPlayerAnEnemy)`,
  `Squad, Cover, Search, Memory, Vision, Hearing, Talk, Steering, Aim, Shoot, ...`; `Enemy GoalEnemy`, `bool IsInCombat, HasEnemy, BotActive`, `ESAINLayer ActiveLayer`.
  These are the classes SAIN's own layers drive every tick, so calling `Mover.WalkToPoint` from outside is overwritten by the next decision unless SAIN's layers are not the active layer.
* SAIN is a set of **BigBrain layers**: `SAIN.Layers.SAINLayer : DrakiaXYZ.BigBrain.Brains.CustomLayer`; `CombatSoloLayer ("Combat Layer")`, `CombatSquadLayer ("Squad Layer")`, `ExtractLayer`, `SAINAvoidThreatLayer`, `SAINFlashedLayer`, `DebugLayer`;
  actions `SAIN.Layers.BotAction : CustomLogic` (`MoveToEngageAction, RushEnemyAction, SearchAction, SeekCoverAction, FollowSearchParty, RegroupAction, ExtractAction, ...`).
  `ESAINLayer { None, Combat, Squad, Extract, Run, AvoidThreat, Flashed }`.
  Registration: `SAIN.BigBrainHandler/BrainAssignment.AddCustomLayersTo{PMCs,Scavs,Raiders,Rogues,Cultists,SpecialBots,LabyrinthBots,BloodHounds}` ->
  `BrainManager.AddCustomLayer(Type, List<string> brainNames, int priority[, List<WildSpawnType> roles])`.
  **Priorities used for PMCs: 99, 80, 85** (ldc.i4 operands in `AddCustomLayersToPMCs`, in call order). Brain-name literals seen: `"PMC"` (raiders), `"ExUsec"` (rogues), `"ArenaFighter"` (bloodhounds), `"PmcBear"`, `"PmcUsec"`; the scav list comes from the preset (not a literal).
* BigBrain 1.5.0 API (`DrakiaXYZ.BigBrain.Brains`): `BrainManager.AddCustomLayer(Type, List<string>, int priority)`, `RemoveLayer(s)`, `RestoreLayer(s)`, `IsCustomLayerActive(BotOwner)`, `GetActiveLayerName(BotOwner)`, `GetActiveLayer/Logic(BotOwner)`;
  `abstract class CustomLayer(BotOwner, int priority) { GetName(); IsActive(); Action GetNextAction(); IsCurrentActionEnding(); Start(); Stop(); BuildDebugText }`,
  `CustomLayer.Action(Type logicType, string reason, ActionData data)`, `abstract class CustomLogic(BotOwner) : CustomLogic<CustomLayer.ActionData> { Start(); Stop(); Update(ActionData) }`.
  MoreBotsAPI's `HuntTargetLayer : CustomLayer` / `GoToCustomAction : CustomLogic` is a working example on this install.
* SAIN server side: `SAIN.ServerInterop.ISainBotTypeRegistry { Task RegisterAsync(SainBotTypeRegistration, CancellationToken) }`,
  `SainBotTypeRegistration { Name; int WildSpawnType; BotDbKey; float DifficultyModifier; Section; Description; List BrainsToApply; List LayersToRemove; BaseBrain }` --
  a server mod can register a NEW bot type with SAIN (that is how MoreBots gets SAIN brains on custom `WildSpawnType` values). Not needed for stock roles.
* The vanilla members the aowlspt SAIN port already names (`mods/sain/README.md`) exist unchanged on 4.1.5: `BotOwner.Mover : BotMover`, `BotMover.GoToPoint(Vector3 pos, bool slowAtTheEnd, float reachDist, bool getUpWithCheck, bool mustHaveWay, bool onlyShortTrie, bool force) : NavMeshPathStatus`,
  `BotOwner.GoToPoint(Vector3, bool, float, bool, bool, bool mustGetUp, bool, bool)`, `BotMover.Stop()`, `Sprint(bool, bool)`, `SetTargetMoveSpeed(float)`, `GoToByWay(Vector3[], float)`,
  `BotOwner.Memory : BotMemory { EnemyInfo GoalEnemy; AddEnemy(IPlayer, BotGroupEnemyInfo, bool); DeleteInfoAboutEnemy(IPlayer); SetUnderFire(IPlayer) }`,
  `BotOwner.BotsGroup : BotsGroup { bool AddEnemy(IPlayer, EBotEnemyCause); RemoveEnemy(IPlayer, EBotEnemyCause); AddNeutral(IPlayer); AddAlly(Player); IsEnemy/IsAlly(IPlayer); Member(int); MembersCount; List<IPlayer> Allies; AddMember(BotOwner) }`,
  `EBotEnemyCause { addPlayer=4, addPlayerToBoss=3, callBot=15, ... }`, `Player.AIData : IAIData { BotOwner BotOwner }`, `GameWorld.MainPlayer`, `GameWorld.AllAlivePlayersList`.

**What SAIN allows externally, plainly:** hearing suppression, personality read, extraction commands, "may this bot quest" checks, and a full BotComponent object graph you can poke but not own. **Movement and targeting orders need a BigBrain layer above SAIN's (priority > 99); no SAIN-side patch is required for that.** A SAIN-side change WOULD be required to (i) make SAIN's own combat logic honour a "hold this position" order while fighting, or (ii) get an event when SAIN changes decision (no public event on `SAINDecisionClass`; `BotComponent.OnBotActivated` is the only public event).

---

## 2. Design: the backend stays the single brain

```
                 aowlspt install                        stock SPT 4.1.5 install
                 ----------------                       ----------------------
 host DLL  <- tarkov.bots.plant / loot.plant  <-  |   Basement.Server (user\mods)  --POST /spt/bots-->   aowlspt-backend.exe :6970
 emulator     (mods/tarkov/emu/planting.nim)     |     Harmony prefix/postfix on               <--groups/limits--   (mods/basement)
                                                  |     BotController.Generate               --GET /spt/waves-->
                                                  |     BotGenerator.PrepareAndGenerateBot     <--waves/bossWaves--
                                                  |     BotInventoryGenerator.GenerateInventory
                                                  |     LocationLifecycleService.GenerateLocationAndLoot
                                                  |
                                                  |   Basement.Client (BepInEx, via aowl.api)  --/events long poll-->
                                                  |     group.spawn -> BotSpawner (positions or anywhere)
                                                  |     npc.goto/hold/follow -> BigBrain layer "Basement" @120 > SAIN 99
                                                  |     npc.attack/stance -> BotsGroup.AddEnemy/RemoveEnemy/AddNeutral/AddAlly
```

(i) **Server mod `mods/basement/spt/Basement.Server`** (built). Four `AbstractPatch`es, each fail-open and loud (a sidecar miss = SPT's own output, one warning line):

| patch | target (MEASURED) | does |
|---|---|---|
| `GenerateBotsPatch` | prefix `BotController.Generate` | `POST /aowlspt/basement/spt/bots {map, raidId=sessionId, wave=n, requested:[{role,limit,difficulty}]}`; answer `limits[]` rewrites `Conditions[].Limit/Difficulty` **only for roles the client asked for** (a role the client did not ask for is refused with a log line: the client only accepts profiles of the role it requested -- new roles go through waves); answer `groups[]` fills `PlanStore` (per session, per role queue of {name, personId, groupId, loadout}) |
| `PrepareAndGenerateBotPatch` | postfix `BotGenerator.PrepareAndGenerateBot` | pops the next planned bot for `details.Role`, writes `Info.Nickname / LowerNickname / MainProfileNickname` (+ `Info.GroupId` only with `writeGroupId=true`, default off, because the client feeds it to `BotsGroup.AddEnemyGroupIfAllowed`) |
| `GenerateInventoryPatch` | prefix `BotInventoryGenerator.GenerateInventory` (`ref BotType botJsonTemplate`) | peeks the same planned bot; if it names a `loadout` role, swaps the template for `ICloner.Clone(BotHelper.GetBotTemplate(loadout))` so SPT generates the kit. Peek/pop agree because GenerateInventory has exactly one call site per bot |
| `LocationWavesPatch` | postfix `LocationLifecycleService.GenerateLocationAndLoot` | `GET /aowlspt/basement/spt/waves?map=<LocationBase.Id>&raidId=`; `{ok, clear, waves:[EFT wave rows], bossWaves:[EFT BossLocationSpawn rows]}` parsed by SPT's `JsonUtil` into SPT's own records; `clear` empties the stock lists first; a wave whose `SpawnPoints`/`BossZone` is not a `BotZoneName` in `SpawnPointParams` is DROPPED with a warning, never guessed |

Plus `StatusRouter` = `GET http://127.0.0.1:6969/aowlspt/basement/spt/status` on the SPT server: planned/named/loadoutSwapped/unplanned counts, per-session pending queues, waves written/dropped, sidecar calls/failures/last error. That is the finished-state readback a verification asserts on.

Spawn TIMES and POINTS on SPT are therefore expressed the way the game expresses them: `Wave.TimeMin/TimeMax + SpawnPoints(zone)` and `BossLocationSpawn.Time/Delay + BossZone` for pre-planned population, and `group.spawn` at scene coordinates for mid-raid materialisation. Free-form coordinates for a WAVE do not exist in the game's data model; the backend maps a scene position to the nearest zone (`SpawnPointParams[].Position` gives it every zone's points) or asks the client to spawn on positions.

(ii) **Client** (built into `Basement.Client`, registered through `AowlEvents.Directives.Register`):

* `GroupSpawn.cs` -- `group.spawn {factionId, count, near{x,y,z}, radiusM, people[], role?, mode?}`:
  `mode=anywhere` -> `BotSpawner.SpawnBotByTypeForce(count, role, difficulty, new BotSpawnParams())`;
  `mode=positions` (default with `near`) -> `GetClosestZone(center)`, `_botCreator` via AccessTools, `new GetProfileDataParams(side, role, difficulty, 0f, new BotSpawnParams(), false)`,
  `await BotCreationData.Create(pd, creator, count, spawner)`, then `SpawnBotsInZoneOnPositions(List<ISpawnPoint>{our ScenePoint rows on a ring of radiusM}, zone, data, cb)`.
  Ack = ACCEPTED; each created bot is reported by an observe `bot.created {seq, nickname, profileId, role}`; failures by `bot.spawn.failed`. Either path generates profiles through `/client/game/bot/generate`, so the server mod names them from the plan.
* `Orders.cs` -- `npc.goto/hold/follow` become a per-ProfileId order and a BigBrain `CustomLayer` **"Basement" at priority 120** on brains `PMC, PmcBear, PmcUsec, ExUsec, ArenaFighter, Assault` (the first five are measured SAIN literals; `Assault` is the convention, unmeasured) whose `IsActive()` is "an order exists"; its `CustomLogic.Update` drives `BotOwner.Mover.GoToPoint(...)` / `Stop()` once per second and clears the order on arrival / `PathInvalid`. `npc.attack` = `BotsGroup.AddEnemy(target, addPlayer)` then the order is cleared so SAIN's combat layer fights; `npc.stance` = AddEnemy / RemoveEnemy+AddNeutral / AddAlly, each verified afterwards by `BotsGroup.IsEnemy(target)` (a check that can fail). Person -> BotOwner through `People.BotFor(personId).AIData.BotOwner`, else a nickname scan of `BotsController.Bots.BotOwners`.

(iii) **Backend**: two routes with the emulator's payload shapes (section 4). `POST /spt/bots` answers exactly `composeBotsPlant(raidId, map)` (`{raidId, map, groups:[{groupId, factionId, role, count, names, x,y,z}]}`) with the SPT-only additions `ok`, `limits`, `loadout`, `personIds`, and the group `role` normalised to one the client requested (SPT's PlanStore is keyed by the requested role; "guard" is a basement notion). `GET /spt/waves` is a stub (`ok:false`) until the world model decides waves.

---

## 3. What was built, how to build it, what a live check must assert

Built 2026-09-07 (outputs in the session scratchpad, nothing installed):

```
mods\basement\spt\Basement.Server   dotnet build -c Release -p:OutDir=<dir>\   -> 0 errors, 0 warnings, Basement.Server.dll 46 KB
                                    refs: SPTarkov.Common/DI/Server.Core/Reflection 4.1.5.0, 0Harmony 2.16.1, SemanticVersioning 3.0 (all <Private>false</Private>)
mods\basement\spt\Basement.Client   dotnet build -c Release -p:OutDir=<dir>\   -> 0 errors (3 warnings pre-existing in other files)
                                    new refs: DrakiaXYZ-BigBrain.dll (plugins), UnityEngine.AIModule; [BepInDependency xyz.drakia.bigbrain hard, me.sol.sain soft]
```

Cecil readback of the built DLLs (`impl`/`callers` verbs): `Basement.Server` declares `BasementServer : IOnLoad`, `ModMetadata : IModMetadata`, `StatusRouter : StaticRouter`, four `: AbstractPatch`; `Basement.Client` declares `BasementLayer : CustomLayer`, `BasementLogic : CustomLogic`, `ScenePoint : ISpawnPoint` and binds `BotSpawner.SpawnBotByTypeForce`, `BotSpawner.SpawnBotsInZoneOnPositions`, `BrainManager.AddCustomLayer` with the measured signatures.

Install (human step, never done by an agent): `Basement.Server.dll` + `config.json` -> `D:\SPT415\SPT_Runtime\user\mods\Basement.Server\`; `Basement.Client.dll` next to `Aowl.Api.dll` in `BepInEx\plugins`; sidecar running on 6970.

Live checks, each one a property of the finished state (PASS / FAIL / INCONCLUSIVE):

1. SPT server log at load: one `[Basement.Server] v0.1.0 ... patches=GenerateBotsPatch,PrepareAndGenerateBotPatch,GenerateInventoryPatch,LocationWavesPatch` line, and `(answers /status)`. Missing line = the DLL did not load (INCONCLUSIVE for everything below).
2. `GET :6969/aowlspt/basement/spt/status` -> `sidecarFailures == 0` and, after one raid start, `plan.waves[session] >= 1` and `named > 0`. `named == 0` with `planned > 0` = FAIL (the postfix did not fire or the roles did not match).
3. Negative: after the raid loads, NO bot in `BotsController.Bots.BotOwners` whose `Profile.Info.Nickname` is in the backend's `names[]` is missing -- i.e. the set of planned names minus the set of live nicknames is empty (a subset check that can fail).
4. Waves: the served `LocationLoot.waves` (capture the `/client/match/local/start` reply) contains every backend wave with a known zone and none with an unknown one; `wavesDropped` on the status route equals the count of unknown-zone rows sent.
5. Loadout: a bot planned with `loadout:"pmcBEAR"` on role `assault` carries a PMC-template kit (armor/rig from the pmc template) -- read `Inventory.items` of the generated `BotBase` in the `/client/game/bot/generate` reply, not the template.
6. `group.spawn`: the ack is `ok:true` AND a `bot.created` observe arrives per bot within 30 s; ack ok with no `bot.created` = FAIL (accepted but never materialised).
7. `npc.goto`: `BrainManager.GetActiveLayerName(bot) == "Basement"` while the order is pending, and the bot's `Position` ends within 1.5 m of the point; the layer name reverting to a SAIN layer afterwards proves the hand-back.

---

## 4. Backend patch block (for the coordinator; `mods/basement/basement.nim` is held by others)

Route constants (next to `SceneRoute`, line ~72):

```nim
  SptBotsRoute   = Base & "/spt/bots"     ## POST {map, raidId, wave, requested[]} -> the emulator's plant shape + limits
  SptWavesRoute  = Base & "/spt/waves"    ## GET ?map=&raidId= -> {ok, clear, waves[], bossWaves[]} (EFT-native rows)
```

Handlers (next to `onScene`, line ~1261). `composeBotsPlant` already produces
`{raidId, map, groups:[{groupId, factionId, role, count, names, x, y, z}]}`
for the emulator; the SPT route reuses it verbatim and only normalises `role`
to a role the client actually requested, because SPT keys its plan by the
requested role and refuses roles the client did not ask for.

```nim
proc onSptBots(url, body, session: string): string =
  ## Basement.Server (SPT 4.1.5) asks once per /client/game/bot/generate.
  ## Same brain, same rows as tarkov.bots.compose; `requested` is the client's
  ## own {role, limit, difficulty} list and every group is re-keyed onto one
  ## of those roles (a "guard" is an "assault" to SPT). `limits` is left out:
  ## SPT keeps the client's counts unless the world decides otherwise.
  if not gEnabled: return disabledJson()
  var map = jr.asText(jr.field(body, "map"), "")
  if map.len == 0: map = queryValue(url, "map")
  let raidId = jr.asText(jr.field(body, "raidId"), "")
  if map.len == 0:
    return errJson("no `map`: POST " & SptBotsRoute & " {map, raidId, wave, requested:[{role,limit,difficulty}]}")
  var firstRole = "assault"
  var requestedRoles: seq[string] = @[]
  let reqJ = jr.field(body, "requested")
  for i in 0 ..< jr.count(reqJ):
    let role = jr.asText(jr.field(jr.at(reqJ, i), "role"), "")
    if role.len > 0:
      requestedRoles.add role
      if requestedRoles.len == 1: firstRole = role
  var text = ""
  withModLock:
    text = composeBotsPlant(raidId, map)
  # Re-key: a group whose role is not one the client asked for is served under
  # the first requested role, and its basement role survives as `factionRole`.
  var groups = arr()
  let groupsJ = jr.field(text, "groups")
  for gi in 0 ..< jr.count(groupsJ):
    let g = jr.at(groupsJ, gi)
    var go = obj()
    let role = jr.asText(jr.field(g, "role"), "")
    var known = false
    for r in requestedRoles:
      if r == role: known = true
    go.put("groupId", jr.asText(jr.field(g, "groupId"), ""))
    go.put("factionId", jr.asText(jr.field(g, "factionId"), ""))
    go.put("factionRole", role)
    go.put("role", if known: role else: firstRole)
    go.put("count", jr.asInt(jr.field(g, "count"), 0))
    var names = arr()
    let namesJ = jr.field(g, "names")
    for ni in 0 ..< jr.count(namesJ):
      names.add jr.asText(jr.at(namesJ, ni), "")
    go.put("names", names)
    go.put("x", jr.asFloat(jr.field(g, "x"), 0.0))
    go.put("y", jr.asFloat(jr.field(g, "y"), 0.0))
    go.put("z", jr.asFloat(jr.field(g, "z"), 0.0))
    groups.add go
  var o = obj()
  o.put("ok", true)
  o.put("raidId", raidId)
  o.put("map", map)
  o.put("wave", jr.asInt(jr.field(body, "wave"), 0))
  o.put("groups", groups)
  gBotsComposeN = gBotsComposeN + 1
  result = done(o).text

proc onSptWaves(url, body, session: string): string =
  ## Stub until the world model owns waves: `ok:false` tells Basement.Server
  ## to keep SPT's stock waves for this raid, and says why on the SPT log.
  ## When it is real, `waves`/`bossWaves` carry EFT-native rows exactly as in
  ## locations/<map>/base.json (Wave: BotPreset, BotSide, SpawnPoints=zone,
  ## WildSpawnType, slots_min/max, time_min/max; BossLocationSpawn: BossName,
  ## BossZone, BossChance, Time, Delay, ...).
  if not gEnabled: return disabledJson()
  let map = queryValue(url, "map")
  var o = obj()
  o.put("ok", false)
  o.put("map", map)
  o.put("clear", false)
  o.put("note", "no wave plan for `" & map & "`: the basement world does not decide waves yet; SPT's own waves stand")
  result = done(o).text
```

Registration (next to `servePrefix(SceneRoute, onScene)`, line ~3073):

```nim
  discard serve(SptBotsRoute, onSptBots)
  discard servePrefix(SptWavesRoute, onSptWaves)
```

Helper names were checked against the sources: `jr.count/at/field/asText/asInt/asFloat`
are `aowl/src/aowlspt/json.nim` (no `items` iterator exists, hence the index
loops); `obj/arr/put/add/done/errJson` are `aowl/src/aowlspt/server.nim`
(`JsonArray.add(string)` writes a JSON string); `disabledJson`, `queryValue`,
`withModLock`, `gBotsComposeN`, `composeBotsPlant` are in `basement.nim`. The
block has NOT been compiled (the file is held by other agents); `aowl build
backend` is the check.

---

## 5. Unproven, in order of risk

1. **No line of section 2 has executed in a live SPT process.** The server mod
   has never been loaded by `SPT.Server.exe`; the client executor has never
   spawned a bot. Every member is measured; every behaviour is inferred.
2. `GetProfileDataParams.spawnTime` semantics (passed `0f`) -- `IsSpawnOnStart()`
   / `IsBossOrFollowerByTime()` read it; a wrong value may make the spawner
   defer. `ScenePoint.Collider == null` -- if `SpawnBotsInZoneOnPositions`
   dereferences it, the first live run says so (the exception is logged and
   observed as `bot.spawn.failed`).
3. `Info.Nickname` set in the postfix vs `MatchBotDetailsCacheService`: the
   cache is filled in `TryGenerateSingleBot` AFTER `PrepareAndGenerateBot`
   returns, so it sees the new name (call order measured), but `BotNameService`'s
   uniqueness cache does not know our names -- two planned bots with equal names
   will both spawn; the backend must keep names unique per raid.
4. BigBrain brain names: `Assault` is unmeasured; if wrong, scavs never get the
   layer (npc.goto on a scav is refused only after the fact -- the layer is
   silently absent). Live check 7 covers it. Priority 120 outranks the measured
   SAIN PMC priorities (99/85/80); SAIN's scav/boss priorities were NOT read.
5. `LocationWavesPatch` relies on SPT's `JsonUtil` honouring the EFT JSON names
   on `Wave`/`BossLocationSpawn` (their `[JsonPropertyName]` attributes were
   not dumped; the records deserialise the game's own `base.json`, so they must).
6. Harmony on an `async Task<>` method (`BotController.Generate`): a PREFIX on
   the outer method runs before the state machine starts and sees the real
   `request` object -- standard Harmony behaviour, but the postfix side of that
   method was deliberately NOT used (it would see an unfinished Task).
7. The client's `people[]` names inside `group.spawn` are not forwarded to the
   server by the client (the server asks the backend directly); the backend
   must answer the pending group's names to the very next `/spt/bots` for that
   map, or the bots get SPT names. That correlation is the backend's job and is
   not written.

---

## 6. Tooling notes (section 10 of CLAUDE.md)

* `MemberCheck` could not answer three questions this task needed, so a scratch
  copy (`mc2`) gained verbs: `virt <Type>` (virtual/override/sealed/visibility per
  method -- the fact that NOTHING in SPT's bot pipeline is virtual decided the
  whole server design), `attrs <Type>` (custom attributes with ctor args and
  named props, plus interfaces -- how `[Injectable(TypePriority=...)]` and
  `[BepInPlugin]` versions were read), `refs` (assembly references + versions),
  `impl <substr>` (types implementing/extending), `strings [substr]` (ldstr per
  method -- how route URLs and brain names were found), `publics <substr>`,
  `msig <Type> <Member>` (FULL parameter type names; `sig` prints `List`1`),
  `ints <Type::Method>` (ldc.i4 operands + calls in order -- how SAIN's layer
  priorities were read). Recommend folding all eight into
  `mods/basement/spt/MemberCheck/Program.cs`; they are ~40 lines.
* `MemberCheck`'s `calls` verb matches `Type::Method` by substring of the NAME,
  so `calls "X::GenerateBot("` silently matches nothing (the `(` is never in the
  name). It should say so instead of printing an empty result.
* The `.claude/hooks/no-compile-in-gitbash.py` hook blocks a Bash command that
  merely CONTAINS a compiler-ish word in a grep pattern (a `grep -n "class LinkShim"`
  batch was refused). Harmless, but the refusal text points at `aowl.exe` for what
  was a text search.
