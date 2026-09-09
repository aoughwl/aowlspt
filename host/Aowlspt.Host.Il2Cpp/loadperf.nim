# ---------------------------------------------------------------------------
# loadperf -- WHERE THE VANILLA RAID LOAD SPENDS ITS THREE MINUTES.
#
# ## The question this answers, and why reading the log cannot
#
# A measured Woods session (client log log_2026.09.01_13-56-55, t0 13:56:56)
# takes ~2m40s from boot to GameRunned, and the client logs NOTHING across the
# three largest stretches of it:
#
#   B  13:57:07.7 /client/game/config answered -> 13:57:14.0 /client/settings
#      requested.  6.3s, no log line at all.  5.9-6.6s in EVERY session,
#      raid or not.
#   C  13:57:36.5 scene preset path:maps/woods_preset.bundle -> 13:57:44.6
#      "Invalid Layer Index".  8.2s silent.  The hideout bundles were loaded
#      at 13:57:35.6 and UNLOADED one second later: dead work.
#   D  13:57:48 -> 13:58:42.3 LocationLoaded.  54s, of which 43.9s is one
#      unbroken silence.  The single largest phase, 27% of the total.
#   E  GameCreated 13:58:44.1 -> PlayerSpawnEvent 13:58:54.7 -> GamePooled
#      13:59:14.9 -> GameRunned 13:59:36.6.
#
# You cannot attribute silence by reading source. This module makes the client
# say where it was, by riding markers the game ALREADY HAS.
#
# ## The one good idea here: the game instruments itself
#
# `EFT.Utilities.ClientMetricsEvents` declares twelve zero-argument instance
# methods whose names ARE the log lines above -- SetMatchingCompleted,
# SetLocationLoaded, SetGamePrepared, SetGameCreated, SetGamePooled,
# SetGameRunned, SetGameSpawn, SetPlayerSpawnEvent, SetGameSpawned,
# SetGameStarting, SetGameStarted. Every one of them is UNIQUE in the
# per-image methodPointers histogram and every one has a clean, fully
# relocatable prologue. Detouring those read-only gives an exact phase
# timeline for C, D and E for free, with no interpretation.
#
# B has no such marker, so it is bracketed by the real methods either side of
# it, found by an offline call-graph scan (E8/E9 rel32 sites in the `il2cpp`
# section, enclosing method by bisect over the methodPointers map):
#
#   EFT.TarkovApplication::StartMenuFirstBatchNetworkLoad @0x97EBC0 is the
#   ONLY direct caller of GlobalsDataLoader::Load @0x99DD10, and that method's
#   local function `<Load>g__LoadClientSettings|1` @0x99F0A0 is what issues
#   /client/settings. So the END of gap B is pinned exactly.
#   The START is not pinned offline: the methods that run just before it in
#   `<PrepareGameJob>d__166::MoveNext` @0x9D04A0 are IsLeaving @0x980DE0,
#   WaitLeaving @0x9813A0, SoundSettingsGroup::CheckMicrophone @0xBE7AF0,
#   GUISounds::PlayMenuBackgroundMusic @0x1483150, ProfileDataLoader::Load
#   @0x9A73D0 / Apply @0x9A75D0 and GlobalsDataLoader::Apply @0x99DF10 -- but
#   the block ORDER inside an async state machine is state order, not run
#   order, so which of them occupies the gap is a PREDICTION this module
#   settles and not a fact it asserts. All seven are bound; whichever one
#   returns immediately before the first-batch marker is the occupant.
#
# E's 20-second GamePooled -> GameRunned stretch has a concrete, non-generic
# explanation and it is bound too: the `EFT.BaseLocalGame`1` generic body
# region (0x3BD8880..0x3BDEE10, from `il2cpp_resolve.py genericmethods`) calls
#   InGameMemoryManagement::RunHeapPreAllocation @0x55E8560
#   InGameMemoryManagement::Collect(int,GCCollectionMode,bool,bool,bool) @0x55E7C30
#   InGameMemoryManagement::EmptyWorkingSet @0x55E7A80
#   InGameMemoryManagement::set_GCEnabled @0x55E7590
# which is exactly the client log's "two GC::Collect", "collectedMemoryGB
# 55.8" and "GC mode switched to Disabled". Three of those four are bound.
#
# ## WHAT IS DELIBERATELY NOT BOUND, and why -- these are facts, not omissions
#
#   HideoutController::StartLoadHideoutBundles  @0x989D60  UNIQUE
#       NOT HOOKABLE. Its prologue is
#           48 83 EC 28        sub  rsp,0x28
#           48 8B 49 20        mov  rcx,[rcx+0x20]
#           48 85 C9           test rcx,rcx
#           74 0B              je   +0xB          <-- RELATIVE BRANCH at
#                                                     offset 11
#       The detour engine needs 14 relocatable bytes (AOWL_JMP_SIZE) and
#       refuses to relocate a relative branch, exactly as it refuses
#       EFT.GameWorld::OnGameStarted (abi/aowlspt_raidstart.h). The dead
#       hideout load is instead observed from the other end, by
#       HideoutController::UnloadHideout @0x989D80 and
#       HideoutGameLoader::UnloadHideout @0x98EBF0, both UNIQUE and both
#       cleanly relocatable. UnloadHideout is called from
#       `<LoadMapAndData>d__202::MoveNext`, which is what makes the load dead.
#
#   InGameMemoryManagement::EmptyWorkingSet     @0x55E7A80  UNIQUE
#       NOT HOOKABLE for the same reason: `75 3A` (jnz) sits at prologue
#       offset 13, inside the 14 bytes the engine must steal.
#
#   EFT.ClientLoadTimeMetrics::BeginGameStartupToMainMenu @0x9686C0  UNIQUE
#   EFT.ClientLoadTimeMetrics::OnMainMenuShown            @0x9687A0  UNIQUE
#       These two would have bracketed gap B with the game's OWN metric, and
#       BOTH are UNHOOKABLE: each begins
#           48 83 EC 28/38     sub rsp,N
#           80 3D <disp32> 00  cmp byte [rip+..],0
#           75 18/3A           jnz ...            <-- offset 11
#       so the relative branch again lands inside the 14 bytes the engine must
#       steal. Their SIBLINGS BeginLocationLoadToRaidStart @0x968A80 and
#       EndLocationLoadToRaidStart @0x968CF0 have ordinary register-save
#       prologues and ARE bound (rows 31/32) -- which is why phase D gets the
#       game's own bracket and phase B does not.
#
#   EVERY `EFT.BaseLocalGame`1` vmethod -- Run @0x3BD90F0, PrepareSession
#       @0x3BD96F0, LocalBotsSpawnInitialization @0x3BD9470,
#       LocalBotsControllerInitialization @0x3BD95B0, SessionRun @0x3BDADB0,
#       Spawn @0x3BDB890, SpawnLoot @0x3BDBAF0, StartGameTimer @0x3BDB840.
#       These are INSTANTIATED GENERIC bodies. They are not in the per-image
#       methodPointers histogram at all, so the sharedness instrument answers
#       UNKNOWN for every one of them -- and UNKNOWN is a REFUSAL, not
#       "unshared" (CLAUDE.md 5). None is bound. The RVAs are recorded here so
#       the next session does not re-derive them, and phase E's INTERNALS stay
#       INCONCLUSIVE while its BOUNDARIES are measured exactly.
#
# ## Safety
#
# This module reads NO GAME MEMORY. Not one pointer, not one field, not one
# argument register. A handler stores a `GetTickCount64` value and increments a
# counter; that is its entire body. So:
#
#   * there is no `aowl_p_p_seh` here, and that is deliberate rather than an
#     omission. The guard is the thing that must never nest, and there is
#     nothing to protect: no dereference exists to fault. `rpStartFired` in
#     raidphase.nim is the same shape for the same reason.
#   * there is no per-frame managed allocation: the handlers touch fixed-size
#     arrays only, and every string in this file is built in `lpDrainTick`,
#     which runs on the ordinary Update drain outside any detour.
#   * every target is byte-verified against the STARTUP PROLOGUE SNAPSHOT
#     (`aowl_pro_verify`, abi/aowlspt_prologue.h), never against live memory,
#     and `aowl_lp_prime_all` primes all of them from `aowl_pro_prime_all`
#     before anything in this host patches anything.
#   * every target is `VirtualQuery`'d for MEM_COMMIT + executable protection
#     before its bytes are compared.
#   * every target was checked UNIQUE offline and the table records that
#     verdict per row; a row that cannot be shown unique is not in the table.
#   * iteration is capped at `LpMaxRows` everywhere.
#   * the flag `loadPerf` defaults OFF.
#   * only the FIRST hit of each row emits a line, so 33 rows can emit at most
#     33 lines plus one summary, however many times a row fires. That is why
#     binding `Diz.Resources.EasyBundle::Load`, which fires per bundle, cannot
#     flood the log.
#   * NO SKIP IS IMPLEMENTED. See `docs`/the report: not one of the four
#     phases has a skip whose safety can be argued from the bytes yet, and the
#     rule is that a skip ships only with a readback that proves the skipped
#     work did not happen. Measure first.
# ---------------------------------------------------------------------------

const
  LpMaxRows = 40
    ## Hard cap on rows walked anywhere in this module. The C table is 33 rows;
    ## this is the bound the Nim side iterates to, so a row added to the C table
    ## without extending this is REFUSED aloud in `lpBind` rather than silently
    ## unhooked.
  LpKind = 27'i32
    ## The single `attachDrain` kind this module uses. Unlike errdlg (which
    ## needs one kind per row because each kind writes a different slot global),
    ## every row here goes through ONE kind and `lpNoteSlot`, exactly as
    ## `uihooks` does with kind 26: `attachDrain` knows the kind but not the
    ## row, so the row being bound is parked in `gLpArming` around the call.
  LpStaleMs = 120000'u64
    ## If SetGameStarted has fired and SetGameRunned has not after this long,
    ## say INCONCLUSIVE. A summary that simply never appears is
    ## indistinguishable from a feature that never armed.

# Row indices. These MUST match `aowl_lp_targets` below, in order; `lpBind`
# asserts the count and refuses the whole feature on a mismatch rather than
# binding rows to the wrong names.
const
  LpIsLeaving      = 0
  LpWaitLeaving    = 1
  LpCheckMic       = 2
  LpMenuMusic      = 3
  LpProfileLoad    = 4
  LpProfileApply   = 5
  LpFirstBatch     = 6
  LpGlobalsLoad    = 7
  LpGlobalsApply   = 8
  LpLocalMatch     = 9
  LpNetMatch       = 10
  LpMatchDone      = 11
  LpLoadMapAndData = 12
  LpHideoutUnload  = 13
  LpHideoutGameUnl = 14
  LpBundlesAsync   = 15
  LpEasyLoad       = 16
  LpEasyCoro       = 17
  LpLocLoaded      = 18
  LpGamePrepared   = 19
  LpGameCreated    = 20
  LpGamePooled     = 21
  LpGameSpawn      = 22
  LpPlayerSpawn    = 23
  LpGameSpawned    = 24
  LpGameStarting   = 25
  LpGameStarted    = 26
  LpGameRunned     = 27
  LpHeapPre        = 28
  LpGcCollect      = 29
  LpGcEnabled      = 30
  LpLocLoadBegin   = 31
  LpLocLoadEnd     = 32
  LpRowCount       = 33

{.emit: """
/* ------------------------------------------------------------------------
 * loadperf's target table.
 *
 * Every RVA below was resolved OFFLINE on build 1.1.0.1.46777 from the
 * per-image Il2CppCodeGenModule.methodPointers table
 * (tools/il2cpp_resolve.py typemethods/member) and every one was separately
 * checked with `il2cpp_resolve.py shared <RVA>`, which answered
 * `UNIQUE owners=1` for all 31. A row whose sharedness verdict was `shared`
 * or `unknown` is not here: `unknown` is a refusal, not a pass.
 *
 * The 16 signature bytes are the ORIGINAL prologue, read out of
 * GameAssembly.dll on disk. They are compared against the STARTUP SNAPSHOT
 * rather than against live memory, so a target another feature patched first
 * still verifies (abi/aowlspt_prologue.h exists for exactly that bug).
 *
 * PHASE letters match the client-log timeline in the Nim header above.
 * ---------------------------------------------------------------------- */
typedef struct AowlLpTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
    char                phase;   /* 'B' 'C' 'D' 'E' */
    /* REGISTER SLOTS the compiled call uses: `this` (0 for a static), the
     * declared arguments, and IL2CPP's trailing `MethodInfo*`. Past FOUR they
     * arrive ON THE STACK, and a POSTFIX detour makes the ORIGINAL read them
     * out of the postfix thunk's own frame -- measured 2026-09-02 on
     * `EFT.UI.MenuScreen::Show(5-arg)`, three dead boots.
     *
     * THREE ROWS HERE EXCEED FOUR, and all 33 were bound POSTFIX until this
     * column existed: [5] ProfileDataLoader::Apply (6), [12]
     * TarkovApplication::LoadMapAndData (7) and [29]
     * InGameMemoryManagement::Collect (6). `LoadMapAndData` is the method that
     * OWNS phase D -- the single most load-bearing row in the table -- and it
     * is the same 7-slot shape as the site that crashed.
     *
     * A row with slots > 4 is bound PREFIX, so its stamp marks the method's
     * ENTRY rather than its RETURN. `lpAtEntry` records which, and every
     * timeline line says so: a timeline that silently mixes entry and return
     * stamps is a measurement that cannot be wrong, and a measurement that
     * cannot be wrong is not a measurement.
     *
     * 0 MEANS UNDECLARED, NOT ZERO SLOTS -- a real method always uses at least
     * one. A row added without this column reads as undeclared and
     * `attachDrain` refuses a postfix on it. Values resolved offline from
     * `Il2CppMethodDefinition.parameterCount@34` + `flags@28 & STATIC`, and
     * re-derived on every build by `tools/drainaudit.py`. */
    int32_t             slots;
} AowlLpTarget;

static const AowlLpTarget aowl_lp_targets[] = {
    /*  0 */ { "EFT.TarkovApplication::IsLeaving", 0x980DE0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x6C,0x24,0x18,0x48,0x89,0x74,0x24,0x20,0x57 }, 16, 'B', 4 },
    /*  1 */ { "EFT.TarkovApplication::WaitLeaving", 0x9813A0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x81,0xEC,0x90,0x00,0x00,0x00,0x80,0x3D,0x85 }, 16, 'B', 3 },
    /*  2 */ { "EFT.Settings.Sound.SoundSettingsGroup::CheckMicrophone", 0xBE7AF0u,
      { 0x40,0x53,0x56,0x57,0x41,0x56,0x41,0x57,0x48,0x83,0xEC,0x50,0x80,0x3D,0xB7,0x21 }, 16, 'B', 1 },
    /*  3 */ { "EFT.UI.GUISounds::PlayMenuBackgroundMusic", 0x1483150u,
      { 0x40,0x53,0x48,0x83,0xEC,0x30,0x80,0x3D,0xED,0xA2,0xC3,0x05,0x00,0x48,0x8B,0xD9 }, 16, 'B', 2 },
    /*  4 */ { "ProfileDataLoader::Load", 0x9A73D0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x70,0x80,0x3D,0x2F,0x1C,0x71,0x06 }, 16, 'B', 3 },
    /*  5 */ { "ProfileDataLoader::Apply", 0x9A75D0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x18,0x4C }, 16, 'B', 6 },
    /*  6 */ { "EFT.TarkovApplication::StartMenuFirstBatchNetworkLoad", 0x97EBC0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57 }, 16, 'B', 3 },
    /*  7 */ { "GlobalsDataLoader::Load", 0x99DD10u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x70,0x80,0x3D,0xB7,0xB2,0x71,0x06 }, 16, 'B', 3 },
    /*  8 */ { "GlobalsDataLoader::Apply", 0x99DF10u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x81,0xEC,0x80,0x00 }, 16, 'B', 4 },
    /*  9 */ { "EFT.TarkovApplication::LocalGameMatching", 0x984170u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x18,0x55 }, 16, 'C', 4 },
    /* 10 */ { "EFT.TarkovApplication::NetworkGameMatching", 0x984360u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x18,0x55 }, 16, 'C', 4 },
    /* 11 */ { "EFT.Utilities.ClientMetricsEvents::SetMatchingCompleted", 0xE072A0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'C', 2 },
    /* 12 */ { "EFT.TarkovApplication::LoadMapAndData", 0x984620u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x48,0x89,0x7C,0x24,0x18,0x4C }, 16, 'D', 7 },
    /* 13 */ { "HideoutController::UnloadHideout", 0x989D80u,
      { 0x40,0x53,0x48,0x83,0xEC,0x70,0x80,0x3D,0xE9,0xF1,0x72,0x06,0x00,0x48,0x8B,0xD9 }, 16, 'C', 2 },
    /* 14 */ { "HideoutGameLoader::UnloadHideout", 0x98EBF0u,
      { 0x40,0x53,0x48,0x83,0xEC,0x70,0x80,0x3D,0x98,0xA3,0x72,0x06,0x00,0x48,0x8B,0xD9 }, 16, 'C', 2 },
    /* 15 */ { "EFT.AssetsManager.AssetsManager::LoadBundlesAsync", 0x1911CD0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x57 }, 16, 'D', 3 },
    /* 16 */ { "Diz.Resources.EasyBundle::Load", 0x2772CC0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x57,0x48,0x81,0xEC,0x90,0x00,0x00,0x00,0x48,0x8B,0xD9 }, 16, 'D', 2 },
    /* 17 */ { "Diz.Resources.EasyBundle::LoadingCoroutine", 0x2773020u,
      { 0x40,0x53,0x48,0x81,0xEC,0x90,0x00,0x00,0x00,0x80,0x3D,0x33,0x2C,0x95,0x04,0x00 }, 16, 'D', 2 },
    /* 18 */ { "EFT.Utilities.ClientMetricsEvents::SetLocationLoaded", 0xE07470u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'D', 2 },
    /* 19 */ { "EFT.Utilities.ClientMetricsEvents::SetGamePrepared", 0xE07640u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 20 */ { "EFT.Utilities.ClientMetricsEvents::SetGameCreated", 0xE07810u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 21 */ { "EFT.Utilities.ClientMetricsEvents::SetGamePooled", 0xE07BC0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 22 */ { "EFT.Utilities.ClientMetricsEvents::SetGameSpawn", 0xE08320u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 23 */ { "EFT.Utilities.ClientMetricsEvents::SetPlayerSpawnEvent", 0xE086D0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 24 */ { "EFT.Utilities.ClientMetricsEvents::SetGameSpawned", 0xE08A80u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 25 */ { "EFT.Utilities.ClientMetricsEvents::SetGameStarting", 0xE08E30u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 26 */ { "EFT.Utilities.ClientMetricsEvents::SetGameStarted", 0xE091E0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 27 */ { "EFT.Utilities.ClientMetricsEvents::SetGameRunned", 0xE07F70u,
      { 0x48,0x89,0x5C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48,0x89,0x7C,0x24,0x20,0x41 }, 16, 'E', 2 },
    /* 28 */ { "InGameMemoryManagement::RunHeapPreAllocation", 0x55E8560u,
      { 0x40,0x55,0x48,0x8B,0xEC,0x48,0x81,0xEC,0x80,0x00,0x00,0x00,0x80,0x3D,0x66,0x00 }, 16, 'E', 1 },
    /* 29 */ { "InGameMemoryManagement::Collect", 0x55E7C30u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x6C,0x24,0x10,0x48,0x89,0x74,0x24,0x18,0x48 }, 16, 'E', 6 },
    /* 30 */ { "InGameMemoryManagement::set_GCEnabled", 0x55E7590u,
      { 0x40,0x53,0x48,0x83,0xEC,0x50,0x80,0x3D,0x35,0x10,0xAF,0x01,0x00,0x0F,0xB6,0xD9 }, 16, 'E', 2 },
    /* 31 -- the game's OWN load-time metric for exactly the span phase D is.
     * Called from `<LoadMapAndData>d__202::MoveNext` @0x9BED7C, so it brackets
     * D from inside the method that owns it. */
    { "EFT.ClientLoadTimeMetrics::BeginLocationLoadToRaidStart", 0x968A80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80 }, 16, 'D', 4 },
    /* 32 */ { "EFT.ClientLoadTimeMetrics::EndLocationLoadToRaidStart", 0x968CF0u,
      { 0x48,0x89,0x5C,0x24,0x10,0x56,0x48,0x83,0xEC,0x30,0x80,0x3D,0x99,0x01,0x75,0x06 }, 16, 'D', 3 },
};

#define AOWL_LP_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_lp_targets) / sizeof(aowl_lp_targets[0])))

static int32_t aowl_lp_verified = 0;
static int32_t aowl_lp_rejected = 0;

static int32_t aowl_lp_target_count(void) { return AOWL_LP_TARGET_COUNT; }

static const char* aowl_lp_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_LP_TARGET_COUNT) return "";
    return aowl_lp_targets[i].name;
}

static uint32_t aowl_lp_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_LP_TARGET_COUNT) return 0u;
    return aowl_lp_targets[i].rva;
}

/* The row's REGISTER-SLOT count. 0 for an out-of-range index -- which reads as
 * UNDECLARED and is refused by `attachDrain`'s postfix gate, never as a
 * plausible small number. */
static int32_t aowl_lp_target_slots(int32_t i) {
    if (i < 0 || i >= AOWL_LP_TARGET_COUNT) return 0;
    return aowl_lp_targets[i].slots;
}

static int32_t aowl_lp_target_phase(int32_t i) {
    if (i < 0 || i >= AOWL_LP_TARGET_COUNT) return (int32_t)'?';
    return (int32_t)aowl_lp_targets[i].phase;
}

/* Prime every row's ORIGINAL prologue into the startup snapshot, before this
 * host patches anything. Called from `aowl_pro_prime_all`; see the forward
 * declaration there. Cheap (33 rows of a 512-row table) and unconditional,
 * because the eager pass exists precisely so that no later verify has to
 * depend on "nothing else patches that". */
static void aowl_lp_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_LP_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_lp_targets[i].rva);
}

/* Resolve one row to a live code pointer, or NULL.
 *
 * VirtualQuery first (committed + executable), then a 16-byte compare against
 * the STARTUP SNAPSHOT via `aowl_pro_verify`. NULL on any failure, so a
 * different game build gets a missed bind and never a jump into unrelated
 * code. `aowl_pro_last_reason_text()` says WHICH failure it was, and only
 * AOWL_PRO_R_MISMATCH licenses "this build changed". */
static void* aowl_lp_target_at(int32_t i) {
    HMODULE ga;
    const AowlLpTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_LP_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;

    t = &aowl_lp_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { aowl_lp_rejected++; return NULL; }
    if (mbi.State != MEM_COMMIT)                 { aowl_lp_rejected++; return NULL; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        aowl_lp_rejected++; return NULL;
    }
    if (!aowl_pro_verify(t->rva, t->sig, t->siglen)) { aowl_lp_rejected++; return NULL; }

    aowl_lp_verified++;
    return (void*)p;
}

static int32_t aowl_lp_verified_count(void) { return aowl_lp_verified; }
static int32_t aowl_lp_rejected_count(void) { return aowl_lp_rejected; }
static const char* aowl_lp_last_reason(void) { return aowl_pro_last_reason_text(); }

/* THE HIT COUNTER. `Diz.Resources.EasyBundle::Load` fires per bundle and is
 * NOT guaranteed to fire on the Unity main thread, so the count is bumped
 * with an interlocked add rather than `++`. A lost increment would not crash
 * anything, but a bundle count is the one number phase D turns on and a
 * silently-wrong one is worse than none. */
static volatile LONG64 aowl_lp_hits[64];
static void aowl_lp_bump(int32_t row) {
    if (row < 0 || row >= 64) return;
    InterlockedIncrement64(&aowl_lp_hits[row]);
}
static int64_t aowl_lp_hits_of(int32_t row) {
    if (row < 0 || row >= 64) return 0;
    return (int64_t)InterlockedCompareExchange64(&aowl_lp_hits[row], 0, 0);
}
""".}

proc cLpTargetCount(): int32 {.importc: "aowl_lp_target_count", nodecl.}
proc cLpTargetAt(i: int32): Il2CppPtr {.importc: "aowl_lp_target_at", nodecl.}
proc cLpTargetName(i: int32): Il2CppPtr {.importc: "aowl_lp_target_name", nodecl.}
proc cLpTargetRva(i: int32): uint32 {.importc: "aowl_lp_target_rva", nodecl.}
proc cLpTargetPhase(i: int32): int32 {.importc: "aowl_lp_target_phase", nodecl.}
proc cLpTargetSlots(i: int32): int32 {.importc: "aowl_lp_target_slots", nodecl.}
proc cLpVerified(): int32 {.importc: "aowl_lp_verified_count", nodecl.}
proc cLpRejected(): int32 {.importc: "aowl_lp_rejected_count", nodecl.}
proc cLpLastReason(): Il2CppPtr {.importc: "aowl_lp_last_reason", nodecl.}
proc cLpBump(row: int32) {.importc: "aowl_lp_bump", nodecl.}
proc cLpHitsOf(row: int32): int64 {.importc: "aowl_lp_hits_of", nodecl.}

# --- host-side state. Fixed size; nothing here allocates. -------------------
var gLpSlotOfRow: array[LpMaxRows, int32]
var gLpFirstMs: array[LpMaxRows, uint64]
var gLpLastMs: array[LpMaxRows, uint64]
var gLpFired: array[LpMaxRows, bool]
var gLpAtEntry: array[LpMaxRows, bool]
  ## True when this row was bound as a PREFIX because its call uses more than
  ## `LpPostfixMaxSlots` register slots, so its stamp marks the method's ENTRY
  ## and not its RETURN. Kept per ROW, not per module, because the table is
  ## MIXED: 30 of the 33 rows are postfix and 3 are not. Every line that prints
  ## a stamp prints this too -- a timeline that quietly mixed the two edges
  ## would read as a measurement and be one only by accident.
var gLpAnnounced: array[LpMaxRows, bool]
var gLpArming = -1
  ## Which row `attachDrain` is currently binding. Read by `lpNoteSlot`, which
  ## `attachDrain` calls from inside its own lock with the claimed slot.
var gLpBound = 0
var gLpFaults = 0
  ## Bind-time refusals. There is no run-time fault path in this module (it
  ## dereferences nothing), so this counts the only thing that CAN fail: a row
  ## that would not verify or would not attach.
var gLpArmedMs = 0'u64
var gLpPending = false      ## at least one first-hit line waits to be emitted
var gLpSummaryDone = false
var gLpStaleSaid = false
var gLpNotBound = ""
var gLpPrefixRows = 0       ## rows bound PREFIX because slots > LpPostfixMaxSlots

const LpPostfixMaxSlots = 4
  ## Mirrors `invoke.nim`'s `PostfixMaxSlots`, and is deliberately a separate
  ## constant read in the same file as the table it applies to. `attachDrain`
  ## enforces the rule regardless of what this says; this only decides which
  ## EDGE this module asks for, so the two can never disagree in the unsafe
  ## direction -- the worst a wrong value here can do is ask for a prefix it
  ## did not need.

proc lpEdgeOf(i: int): string =
  ## "return" or "ENTRY", for any line that prints a stamp for row `i`.
  if i >= 0 and i < LpMaxRows and gLpAtEntry[i]: "ENTRY" else: "return"

proc lpNoteSlot*(claimed: int32) =
  ## Called from `attachDrain`'s kind chain with the slot it just claimed.
  ## `attachDrain` knows the kind but not the row, so `lpBind` parks the row in
  ## `gLpArming` around the call. Same shape as `uihNoteSlot`.
  if gLpArming >= 0 and gLpArming < LpMaxRows:
    gLpSlotOfRow[gLpArming] = int32(claimed)

proc lpDisabled*(): bool = not gLpOn or gLpBound == 0

proc lpSlotFired*(slot: int32): bool =
  ## Dispatched from BOTH `patchFired` and `patchReturned` by slot identity, on
  ## whatever thread the patched method runs on. Both, because the table is
  ## MIXED: a row whose call uses more than `LpPostfixMaxSlots` register slots
  ## is bound PREFIX (see the `slots` column) and can only ever arrive through
  ## `patchFired`. A slot is one or the other, never both, so no row can be
  ## stamped twice for one call. It reads NO register and touches NO game memory:
  ## one array compare, one timestamp, one interlocked increment. That is why
  ## it opens no SEH guard -- there is nothing here that can fault, and
  ## `aowl_p_p_seh` is not re-entrant, so a guard that protects nothing is a
  ## hazard rather than a precaution.
  ##
  ## Returns true when the slot was one of ours, so the caller can return
  ## immediately. It NEVER suppresses the original, on either edge: the game
  ## gets exactly what it produced.
  ##
  ## The early-out matters: `patchReturned` fires for OTHER features' postfix
  ## slots too -- the mode-text rider on `PreloaderUI::Update` fires every
  ## frame -- and with the flag off there is nothing here to match, so the
  ## 33-row scan must not run at all.
  if gLpBound == 0: return false
  var i = 0
  while i < LpRowCount and i < LpMaxRows:
    if gLpSlotOfRow[i] == slot:
      let now = cNowMs()
      if not gLpFired[i]:
        gLpFired[i] = true
        gLpFirstMs[i] = now
        gLpPending = true
      gLpLastMs[i] = now
      cLpBump(int32(i))
      return true
    inc i
  false

proc lpPhaseOf(i: int): string =
  let c = cLpTargetPhase(int32(i))
  if c == int32(ord('B')): "B"
  elif c == int32(ord('C')): "C"
  elif c == int32(ord('D')): "D"
  elif c == int32(ord('E')): "E"
  else: "?"

proc lpSecs(a, b: uint64): string =
  ## `b - a` as seconds with one decimal, or a refusal. NEVER returns "0.0s"
  ## for a span whose ends were not both observed: an unmeasured span that
  ## prints as zero is the check-that-cannot-fail shape.
  if a == 0'u64 or b == 0'u64: return "n/a(one end never fired)"
  if b < a: return "n/a(out of order)"
  let d = b - a
  $(d div 1000'u64) & "." & $((d mod 1000'u64) div 100'u64) & "s"

proc lpAt(i: int): string =
  ## The row's first hit, relative to the arm. `gLpArmedMs` is stamped at the
  ## END of `lpBind`, so a row that fires between its own attach and that stamp
  ## would underflow an unsigned subtract into a nonsense number -- which is
  ## exactly the plausible-looking wrong value this project keeps paying for.
  ## Clamped, and the clamp is stated rather than hidden.
  ##
  ## The EDGE is part of the answer, not decoration: rows over
  ## `LpPostfixMaxSlots` are stamped at ENTRY and the rest at RETURN, and a
  ## reader comparing two stamps has to know which is which or the gap between
  ## them is a number with no meaning.
  if not gLpFired[i]: "never"
  elif gLpFirstMs[i] < gLpArmedMs: "+0.0s(fired during the bind pass," &
       lpEdgeOf(i) & ")"
  else: "+" & $((gLpFirstMs[i] - gLpArmedMs) div 1000'u64) & "." &
        $(((gLpFirstMs[i] - gLpArmedMs) mod 1000'u64) div 100'u64) & "s(" &
        lpEdgeOf(i) & ")"

proc lpFirst(a, b: int): uint64 =
  ## The earlier of two rows that fired, 0 if neither did. Used where the game
  ## takes one of two mutually exclusive routes (LocalGameMatching vs
  ## NetworkGameMatching): asserting one of them would make the span
  ## unmeasurable in the other mode and report it as "n/a" forever.
  if gLpFired[a] and gLpFired[b]:
    (if gLpFirstMs[a] <= gLpFirstMs[b]: gLpFirstMs[a] else: gLpFirstMs[b])
  elif gLpFired[a]: gLpFirstMs[a]
  elif gLpFired[b]: gLpFirstMs[b]
  else: 0'u64

proc lpLargestGap(): string =
  ## The biggest silence between two consecutive markers that actually fired.
  ## This is the whole point of the module: it names the phase to attack next
  ## instead of leaving it to be inferred from a wall of timestamps. Selection
  ## over at most `LpRowCount` rows, no allocation beyond the result string.
  var bestFrom = -1
  var bestTo = -1
  var bestD = 0'u64
  var i = 0
  while i < LpRowCount:
    if gLpFired[i]:
      # find the row with the smallest first-hit time strictly greater than i's
      var j = 0
      var nxt = -1
      var nxtMs = 0'u64
      while j < LpRowCount:
        if gLpFired[j] and gLpFirstMs[j] > gLpFirstMs[i]:
          if nxt < 0 or gLpFirstMs[j] < nxtMs:
            nxt = j
            nxtMs = gLpFirstMs[j]
        inc j
      if nxt >= 0:
        let d = nxtMs - gLpFirstMs[i]
        if d > bestD:
          bestD = d
          bestFrom = i
          bestTo = nxt
    inc i
  if bestFrom < 0:
    return "LARGEST GAP: INCONCLUSIVE (fewer than two markers fired)"
  "LARGEST GAP " & readCString(cLpTargetName(int32(bestFrom))) & " -> " &
    readCString(cLpTargetName(int32(bestTo))) & " = " &
    lpSecs(gLpFirstMs[bestFrom], gLpFirstMs[bestTo]) &
    " (phase " & lpPhaseOf(bestFrom) & "->" & lpPhaseOf(bestTo) & ")"

proc lpEmitSummary() =
  gLpSummaryDone = true
  let matchStart = lpFirst(LpLocalMatch, LpNetMatch)
  okLog "loadperf SUMMARY (GetTickCount64, ~15.6ms resolution; all times " &
        "relative to the moment loadperf ARMED, not to client start): " &
        "B(first-batch -> /client/settings issued)=" &
        lpSecs(gLpFirstMs[LpFirstBatch], gLpFirstMs[LpGlobalsLoad]) &
        " C(matching -> LoadMapAndData)=" &
        lpSecs(matchStart, gLpFirstMs[LpLoadMapAndData]) &
        " D(LoadMapAndData -> LocationLoaded)=" &
        lpSecs(gLpFirstMs[LpLoadMapAndData], gLpFirstMs[LpLocLoaded]) &
        " D'(the game's OWN Begin/EndLocationLoadToRaidStart)=" &
        lpSecs(gLpFirstMs[LpLocLoadBegin], gLpFirstMs[LpLocLoadEnd]) &
        " E(GameCreated -> GameRunned)=" &
        lpSecs(gLpFirstMs[LpGameCreated], gLpFirstMs[LpGameRunned]) &
        " | pooled->runned=" &
        lpSecs(gLpFirstMs[LpGamePooled], gLpFirstMs[LpGameRunned]) &
        " spawn->pooled=" &
        lpSecs(gLpFirstMs[LpPlayerSpawn], gLpFirstMs[LpGamePooled]) &
        " | " & lpLargestGap()
  okLog "loadperf BUNDLES: EasyBundle::Load n=" & $cLpHitsOf(int32(LpEasyLoad)) &
        " spanning " & lpSecs(gLpFirstMs[LpEasyLoad], gLpLastMs[LpEasyLoad]) &
        ", LoadingCoroutine n=" & $cLpHitsOf(int32(LpEasyCoro)) &
        ", AssetsManager::LoadBundlesAsync n=" & $cLpHitsOf(int32(LpBundlesAsync)) &
        " | hideout: UnloadHideout n=" & $cLpHitsOf(int32(LpHideoutUnload)) &
        " at " & lpAt(LpHideoutUnload) &
        ", HideoutGameLoader::UnloadHideout n=" &
        $cLpHitsOf(int32(LpHideoutGameUnl)) &
        " | memory: RunHeapPreAllocation at " & lpAt(LpHeapPre) &
        " n=" & $cLpHitsOf(int32(LpHeapPre)) &
        ", Collect n=" & $cLpHitsOf(int32(LpGcCollect)) &
        ", set_GCEnabled n=" & $cLpHitsOf(int32(LpGcEnabled)) &
        " at " & lpAt(LpGcEnabled)
  # The B occupant, stated as a measurement or refused. This is the line the
  # whole phase-B question turns on, and it must be able to say "I do not
  # know".
  if gLpFired[LpFirstBatch]:
    var occ = -1
    var occMs = 0'u64
    var i = 0
    while i < LpRowCount:
      if gLpFired[i] and lpPhaseOf(i) == "B" and i != LpFirstBatch and
         i != LpGlobalsLoad and gLpFirstMs[i] <= gLpFirstMs[LpFirstBatch]:
        if occ < 0 or gLpFirstMs[i] > occMs:
          occ = i
          occMs = gLpFirstMs[i]
      inc i
    if occ < 0:
      warn "loadperf PHASE B: INCONCLUSIVE -- StartMenuFirstBatchNetworkLoad " &
           "fired at " & lpAt(LpFirstBatch) & " but NONE of the six candidate " &
           "predecessors fired before it. Either loadperf armed after they ran " &
           "(it armed " & $gLpArmedMs & "ms after boot) or the gap is occupied " &
           "by something not in this table. This is NOT 'the gap is empty'."
    else:
      okLog "loadperf PHASE B: the last bound method to return before " &
            "StartMenuFirstBatchNetworkLoad was " &
            readCString(cLpTargetName(int32(occ))) & " at " & lpAt(occ) &
            ", " & lpSecs(occMs, gLpFirstMs[LpFirstBatch]) & " before it. " &
            "That interval is the silent gap; the named method is where it " &
            "ENDS, which makes it the occupant only if the interval is the " &
            "whole 5.9-6.6s the client log shows."
  else:
    warn "loadperf PHASE B: INCONCLUSIVE -- StartMenuFirstBatchNetworkLoad " &
         "never fired this run, so gap B was not measured at all."
  if gLpNotBound.len > 0:
    warn "loadperf: these rows were NOT bound this run and every span that " &
         "depends on them reads n/a: " & gLpNotBound

proc lpDrainTick*() =
  ## Rides the existing `TarkovApplication::Update` drain. Installs no detour
  ## of its own, opens no guard, and reads no game memory. Every string in this
  ## module is built HERE, never inside a detour handler.
  ##
  ## NOTE for whoever reads the resulting log: during the 43.9-second silent
  ## stretch of phase D the Unity main thread is not running Update, so these
  ## lines FLUSH LATE. The timestamps are captured in the handler at the moment
  ## the method returned, so the measurement is unaffected -- only the moment
  ## the line appears in the file is.
  if lpDisabled(): return
  if gLpPending:
    gLpPending = false
    var i = 0
    while i < LpRowCount and i < LpMaxRows:
      if gLpFired[i] and not gLpAnnounced[i]:
        gLpAnnounced[i] = true
        # Only the FIRST hit of a row is ever announced, which is what makes a
        # per-bundle target safe to bind.
        info "loadperf " & lpAt(i) & " phase " & lpPhaseOf(i) & "  " &
             readCString(cLpTargetName(int32(i)))
      inc i
  if not gLpSummaryDone and gLpFired[LpGameRunned]:
    lpEmitSummary()
  elif not gLpSummaryDone and not gLpStaleSaid and gLpFired[LpGameStarted] and
       (cNowMs() - gLpFirstMs[LpGameStarted]) > LpStaleMs:
    gLpStaleSaid = true
    warn "loadperf: SetGameStarted fired at " & lpAt(LpGameStarted) &
         " but SetGameRunned has not fired " & $(LpStaleMs div 1000'u64) &
         "s later. No summary will be printed for this raid. INCONCLUSIVE -- " &
         "either the row did not bind (see the ARMED line) or the raid never " &
         "reached GameRunned."

proc lpStatus*(): string =
  ## One line for `state` / the boot table. Three outcomes, never two.
  if not gLpOn:
    "loadperf OFF (flag loadPerf)"
  elif gLpBound == 0:
    "loadperf ARMED-BUT-DEAD: 0 of " & $LpRowCount & " targets bound"
  else:
    "loadperf ARMED " & $gLpBound & "/" & $LpRowCount & " targets, " &
      $gLpFaults & " refused; summary " &
      (if gLpSummaryDone: "PRINTED" else: "not yet (needs SetGameRunned)")

proc lpBind*(verbose: bool): bool =
  ## Installs one READ-ONLY POSTFIX detour per verified row. Flag-gated on
  ## `loadPerf`, default OFF.
  ##
  ## Binding is BEST-EFFORT PER ROW, and the rows that did not bind are NAMED
  ## with their RVAs: a timeline missing a marker must say which marker is
  ## missing, or every span that depends on it reads as an absence rather than
  ## as a refusal.
  if not gLpOn: return false
  if gLpBound > 0: return true
  if not gReady or gDisableDrain:
    warn "loadperf: the detour engine is not ready (or bridgeDisableDrain is " &
         "set), so NOTHING was bound. This is our state, not the client's."
    return false

  var i = 0
  while i < LpMaxRows:
    gLpSlotOfRow[i] = -1
    inc i

  let count = cLpTargetCount()
  if int(count) != LpRowCount or LpRowCount > LpMaxRows:
    warn "loadperf: aowl_lp_targets has " & $int(count) & " rows but the Nim " &
         "side names " & $LpRowCount & " (cap " & $LpMaxRows & "). REFUSING to " &
         "bind any of them: an index mismatch would attribute one method's " &
         "timestamp to another method's name, which is worse than no timeline."
    return false

  i = 0
  while i < int(count) and i < LpMaxRows:
    let spec = readCString(cLpTargetName(int32(i)))
    let fn = cLpTargetAt(int32(i))
    if fn == nil:
      gLpFaults = gLpFaults + 1
      gLpNotBound = gLpNotBound & (if gLpNotBound.len > 0: ", " else: "") &
                    spec & "@0x" & hexOf(uint64(cLpTargetRva(int32(i)))) &
                    " (" & readCString(cLpLastReason()) & ")"
      inc i
      continue
    gLpArming = i
    # PREFIX OR POSTFIX, decided from the table's `slots` column and never from
    # taste. Past four register slots the arguments arrive on the STACK and the
    # postfix thunk would feed the original its own frame -- see the column's
    # banner. `attachDrain` refuses that shape outright, so asking for it here
    # would lose the row entirely rather than crash; asking for a PREFIX keeps
    # the marker and costs only the entry-vs-return distinction, which is
    # recorded and printed rather than glossed over.
    let slots = int(cLpTargetSlots(int32(i)))
    if slots < 1:
      gLpFaults = gLpFaults + 1
      gLpNotBound = gLpNotBound & (if gLpNotBound.len > 0: ", " else: "") &
                    spec & " (no `slots` in the C table -- source drift in " &
                    "THIS repo, not a game build difference)"
      gLpArming = -1
      inc i
      continue
    let post = slots <= LpPostfixMaxSlots
    gLpAtEntry[i] = not post
    if not post: inc gLpPrefixRows
    let attached = attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                               LpKind, post, int32(slots))
    gLpArming = -1
    if attached:
      # `lpNoteSlot` wrote the slot while `gLpArming` held this row. If it did
      # not -- which would mean the kind chain never reached us -- the row is
      # counted as a refusal rather than as a bound row that silently never
      # fires.
      if gLpSlotOfRow[i] >= 0:
        gLpBound = gLpBound + 1
      else:
        gLpFaults = gLpFaults + 1
        warn "loadperf: attachDrain reported success for " & spec &
             " but lpNoteSlot recorded no slot, so kind " & $LpKind &
             " is not wired into attachDrain's kind chain. That row will " &
             "never fire; the timeline is incomplete and this line is why."
    else:
      gLpFaults = gLpFaults + 1
      gLpNotBound = gLpNotBound & (if gLpNotBound.len > 0: ", " else: "") &
                    spec & "@0x" & hexOf(uint64(cLpTargetRva(int32(i)))) &
                    " (attach refused)"
    inc i

  gLpArmedMs = cNowMs()

  if gLpBound == 0:
    warn "loadperf is ON but NONE of the " & $int(count) & " targets bound (" &
         $int(cLpVerified()) & " verified, " & $int(cLpRejected()) &
         " rejected). No load timeline will be produced this run. Not bound: " &
         gLpNotBound
    return false

  okLog "loadperf ARMED: " & $gLpBound & " of " & $int(count) &
        " read-only detours on the vanilla raid-load path -- " &
        $(gLpBound - gLpPrefixRows) & " POSTFIX (stamped at RETURN) and " &
        $gLpPrefixRows & " PREFIX (stamped at ENTRY, because their calls use " &
        "more than " & $LpPostfixMaxSlots & " register slots and a postfix " &
        "would make the ORIGINAL read its stack arguments out of the thunk's " &
        "own frame). Every stamp printed by this module says which edge it " &
        "is; the two are NOT interchangeable and are not averaged. (" &
        $int(cLpVerified()) & " prologue-verified against the startup " &
        "snapshot, " & $int(cLpRejected()) & " rejected). It reads NO game " &
        "memory -- one timestamp and one interlocked counter per hit -- and " &
        "never suppresses an original. Read it with " &
        "`python tools/hostlog.py feature loadperf`."
  if gLpNotBound.len > 0:
    warn "loadperf: not bound: " & gLpNotBound
  okLog "loadperf NOTE: three things are deliberately NOT bound and are not " &
        "omissions. HideoutController::StartLoadHideoutBundles @0x989d60 has " &
        "a relative `je` at prologue offset 11, inside the 14 bytes the " &
        "engine must steal, so it is UNHOOKABLE on this build (the dead " &
        "hideout load is observed from UnloadHideout instead). " &
        "InGameMemoryManagement::EmptyWorkingSet @0x55e7a80 has a `jnz` at " &
        "offset 13 for the same reason. Every EFT.BaseLocalGame`1 vmethod " &
        "(Run @0x3bd90f0, PrepareSession @0x3bd96f0, SessionRun @0x3bdadb0, " &
        "Spawn @0x3bdb890, SpawnLoot @0x3bdbaf0) is an INSTANTIATED GENERIC " &
        "body, absent from the methodPointers histogram, so its sharedness " &
        "verdict is UNKNOWN -- a refusal, not a pass. Phase E's boundaries " &
        "are measured; its internals stay INCONCLUSIVE."
  true
