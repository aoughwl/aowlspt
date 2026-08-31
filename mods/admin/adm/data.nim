## The ESP data pass + cheats -- pure field-offset memory reads/writes and a
## static byte-patch. No il2cpp reflection, no managed method calls, no Unity
## thread.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE WAS REWRITTEN (three MEASURED defects, 2026-08-25)
## ---------------------------------------------------------------------------
##
## The previous version resolved every offset at runtime by NAME, through
## `objectClass()` / `findClass()` / `findField()`. Measured problems:
##
##  1. **`objectClass()` is `il2cpp_object_get_class`, which FAULTS on this
##     build** (CLAUDE.md 5: reflection is dead -- object_get_class,
##     class_get_name, value_box and field iteration all fault). Every offset
##     lookup in the old file ran it on a live game object. That is not a
##     degrade path, it is a crash path.
##
##  2. **`<CameraPosition>k__BackingField` is a `Transform`, not a `Vector3`.**
##     The old file's own header asserted "Vector3 (the eye position)" and read
##     three floats straight off it. Those 12 bytes are a managed object header
##     (klass pointer + monitor) reinterpreted as floats -- every ESP position
##     was garbage. The NAME had been verified against metadata; the TYPE had
##     not. Measured with two independent tools:
##       tools/fldoff.py fields EFT.Player
##       tools/il2cpp_resolve.py ... fields EFT.Player
##     both report `0x3b8 inst <CameraPosition>k__BackingField Transform`.
##
##  3. **`Stamina.TotalCapacity` is a `Compute<float>`, not a float.** The old
##     file read it with rdF32 and then WROTE that value into `Current` -- a
##     blind write of the low half of a pointer. `PhysicalBase.StaminaCapacity`
##     @0x8c is the real float.
##
## ---------------------------------------------------------------------------
## PROVENANCE OF EVERY OFFSET BELOW
## ---------------------------------------------------------------------------
##
## All offsets are STATIC constants measured offline from this build's
## `GameAssembly.dll` + decrypted global-metadata, via
## `Il2CppMetadataRegistration.fieldOffsets`. Reproduce with:
##
##   python tools/fldoff.py fields EFT.GameWorld
##   python tools/fldoff.py fields EFT.Player
##   python tools/fldoff.py fields EFT.MovementContext
##   python tools/fldoff.py fields PhysicalBase
##   python tools/fldoff.py fields Stamina
##
## `fldoff.py` runs a mandatory self-check first (System.String._stringLength
## @0x10 / _firstChar@0x14) and prints nothing else if it fails, so a metadata
## layout change is announced rather than silently misread.
##
## They are constants, not runtime lookups, precisely because the runtime lookup
## needed a faulting API. The cost is that a Tarkov update invalidates them --
## which is why `adminDiag()` reports every hop and `dataDefectText()` names the
## first one that did not validate, instead of drawing nothing and saying
## nothing.
##
## ---------------------------------------------------------------------------
## THE ONE REMAINING GATE, STATED HONESTLY
## ---------------------------------------------------------------------------
##
## **World -> screen projection -- NOW BOUND.** The old file's plan (read the
## matrix out of the native camera at a hand-set `VpNativeOff`) is still NOT
## used: that offset is not in il2cpp metadata, cannot be measured offline, and
## would have been a guess.
##
## What is used instead is a byte-verified DIRECT CALL at three static RVAs --
## `Camera::get_main` @0x5260400, `Camera::get_worldToCameraMatrix` @0x525F2A0
## and `Camera::get_projectionMatrix` @0x525F380, the last two in the Win64
## hidden-return-buffer (sret) shape. Direct RVA calls DO work on this build;
## only reflection is dead. Every byte, and the disassembly that establishes the
## argument shape, is recorded in `abi/aowlspt_admin.h`.
##
## Those are Unity calls, so they run on Unity's thread -- `admin.nim` drives
## `camSample()` from `everyMain`, gated on the host confirming its main-thread
## drain has already fired (fact #136). This file, which runs on the mod's own
## thread, only ever does the pure arithmetic in `aowl_admin_project`.
##
## `espProjectable()` is now `camReady()`. When it is false the ESP capability
## bit stays 0, the HUD draws the mode dim, and `camStateText()` says WHICH of
## not-bound / never-sampled / stale / self-disabled it is. It does not pretend,
## and it never reports a projection failure as "not in a raid".

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import aowlspt/game    # whenReady/ready -- the boot-safe readiness poll
import shared
import admprof
# Prototypes only -- `adm/admprof.nim` owns the state (AOWL_ADMPROF_IMPL).
{.emit: """#include "aowlspt_admprof.h" """.}

# il2cpp x64 memory layout -- ABI constants, stable across builds.
const
  ListItemsOff  = 0x10   ## List<T>._items (the T[] backing array)
  ListSizeOff   = 0x18   ## List<T>._size (int)
  ArrDataOff    = 0x20   ## first element of an il2cpp array on x64

# ---- MEASURED static field offsets, build 1.1.0.1.46777 ----
const
  # EFT.GameWorld
  GwAllAlivePlayers = 0x1C8   ## List<Player>   (preferred: concrete Player)
  GwRegisteredPlrs  = 0x1D0   ## List<IPlayer>  (fallback)
  GwMainPlayer      = 0x230   ## Player

  # EFT.Player
  PlMovementContext = 0x60    ## MovementContext -- the pose the client reads
  PlPhysical        = 0x9D8   ## PhysicalBase
  PlAIData          = 0xA00   ## IAIData; non-null => this player is a bot
  PlIsYou           = 0xB89   ## <IsYourPlayer>k__BackingField : bool. MEASURED
                              ## `python tools/fldoff.py fields EFT.Player`
                              ## (self-check passed). The ROBUST local-player
                              ## identity: true only on the local instance,
                              ## independent of GameWorld+0x230, which can read
                              ## null on a frame and let self leak into the draw.

  # ---- FACTION / SIDE ------------------------------------------------------
  # The "all bots show as SCAV" bug (task 1) was a check that could ONLY ever
  # say scav: the old code set the side purely from whether AIData was non-null
  # -- every bot has AIData, so every bot read as scav and the REAL faction was
  # never read at all (CLAUDE.md 9b). The real side lives on the Profile, not on
  # the Player, and is reached through:
  #     Player -> Profile -> Info(ProfileInfo) -> Side (EPlayerSide, i32 inline)
  #                                            -> Settings(ProfileSettings) -> Role
  # MEASURED 2026-08-28, each dump's mandatory System.String self-check
  # (_stringLength@0x10 / _firstChar@0x14) PASSED so the offsets are trusted
  # (CLAUDE.md 5):
  #     python tools/fldoff.py fields EFT.Player          -> <Profile>@0x9C0
  #     python tools/fldoff.py fields EFT.Profile         -> Info@0x48
  #     python tools/fldoff.py fields EFT.ProfileInfo     -> <Side>@0x48, <Settings>@0x78
  #     python tools/fldoff.py fields EFT.ProfileSettings -> Role@0x10
  # EPlayerSide and WildSpawnType are enums (value types): the value__ is stored
  # INLINE where the field sits, so each is a plain guarded i32 read, not a hop.
  PlProfile         = 0x9C0   ## EFT.Player.<Profile>k__BackingField : Profile
  ProfInfo          = 0x48    ## EFT.Profile.Info : ProfileInfo
  PInfoSide         = 0x48    ## EFT.ProfileInfo.<Side> : EPlayerSide (i32 inline)
  PInfoSettings     = 0x78    ## EFT.ProfileInfo.<Settings> : ProfileSettings
  PSettingsRole     = 0x10    ## EFT.ProfileSettings.Role : WildSpawnType (i32 inline)

  # ---- EFT.MovementContext -------------------------------------------------
  # THERE IS NO POSITION FIELD HERE. `PreviousPosition` @0x370 used to be read
  # as "the real world position" and it is not: the offset is CORRECT (metadata
  # names the field at exactly 0x370) and the field is PERMANENTLY ZERO on this
  # build -- 66331 readable reads in a live raid, every one exactly (0,0,0),
  # measured 2026-08-28. That is why `positions` reported
  # "FAIL no player position passed the finite/bounded check" in a raid; it was
  # never the sampler's timing. The constant is deliberately GONE rather than
  # left unused, so nothing reaches for it again. The live pose comes from
  # `posSample()` below, a byte-verified direct call at
  # `EFT.Player::get_Position` @0x6F32C0 -- see abi/aowlspt_admin.h.

  # PhysicalBase
  PhStamina         = 0x68    ## Stamina
  PhStaminaCapacity = 0x8C    ## float -- the true max (NOT Stamina.TotalCapacity,
                              ## which is a Compute<float> reference)

  # Stamina
  StCurrent         = 0x10    ## float

  # ---- NO WEIGHT ----------------------------------------------------------
  # MEASURED 2026-08-28, `python tools/fldoff.py fields PhysicalBase`, which
  # printed a real offset (not `--`, not `GENERIC -- NO LAYOUT`) for every one:
  #   0x1c  Overweight        float   public
  #   0x20  WalkOverweight    float   public
  #   0x24  WalkSpeedLimit    float   public
  #   0xd0  SprintOverweight  float   protected
  #   0x11c _encumbered       bool    private
  #   0x11d _overEncumbered   bool    private
  # These are the SAME object the already-shipping stamina write reaches
  # (Player+0x9D8 -> PhysicalBase), so no new hop is introduced: the pointer
  # chain is one the mod has been validating in a live raid all along.
  #
  # WHY THESE SIX AND NOT A WEIGHT FIELD. `PreviousWeight` @0xd4 is a CACHE of
  # the inventory total, recomputed from the inventory whenever
  # `_weightIsOutOfDate` is set; writing it changes a number nothing reads back
  # out. The four floats above are what the movement code consumes, and the two
  # bools are what the HUD and the sprint gate consume. Zeroing the inputs the
  # consumers read is the write; faking the source is not.
  PhOverweight       = 0x1C
  PhWalkOverweight   = 0x20
  PhWalkSpeedLimit   = 0x24
  PhSprintOverweight = 0xD0
  PhEncumbered       = 0x11C
  PhOverEncumbered   = 0x11D

  # ---- NO RECOIL / SWAY ---------------------------------------------------
  # MEASURED 2026-08-28 with `tools/fldoff.py fields <T>` at each hop; the type
  # at each step is the DECLARED field type printed by that command, so the
  # chain is typed the whole way down rather than assumed from a name:
  #   EFT.Player                      0x3c0 <ProceduralWeaponAnimation>k__BackingField
  #                                         : ProceduralWeaponAnimation
  #   ProceduralWeaponAnimation       0x70  Shootingg      : ShotEffector
  #                                   0x2b0 AimSwayMax     : Vector3
  #                                   0x2bc AimSwayMin     : Vector3
  #                                   0x3f8 _swayStrength  : float
  #                                   0x4a4 _swayFactor    : float
  #   ShotEffector                    0x20  NewShotRecoil  : NewRecoilShotEffect
  #   NewRecoilShotEffect             0x11  RecoilEffectOn : bool
  #
  # `RecoilEffectOn` is the pipeline's OWN master switch -- a field the game
  # already reads as a kill switch -- which is why it is preferred over zeroing
  # the twenty-odd strength vectors underneath it. It is a `bool`, i.e. ONE
  # byte, and is read/written through `rdBool`/`wrBool` for that reason.
  #
  # NOT A DETOUR AND NOT A PATCH. Every line of this is a field write on an
  # instance owned by the local player, so there is no shared-RVA blast radius
  # to check and nothing to byte-verify: `sharedness()` is a question about code
  # addresses and none is taken here.
  PlPwAnim           = 0x3C0
  PwShootingg        = 0x70
  PwAimSwayMax       = 0x2B0   ## Vector3
  PwAimSwayMin       = 0x2BC   ## Vector3
  PwSwayStrength     = 0x3F8
  PwSwayFactor       = 0x4A4
  SeNewShotRecoil    = 0x20
  NrRecoilEffectOn   = 0x11    ## bool -- ONE byte

## Box height. `EFT.Player::get_Position` returns the BodyTransform origin, i.e.
## the player ROOT (feet), so the head is one standing height above it. 1.8 m is
## a drawing constant, NOT a measured field -- not dressed up as one.
const PlayerHeightM = 1.8

# God mode. `EFT.Player::ApplyDamageInfo`, MEASURED:
#   * RVA 0x731480, prologue `48 89 5C 24 20` -- byte-verified against the real
#     D:/Games/Tarkov/GameAssembly.dll before any write.
#   * returns **void** (metadata returnType@8 -> 0x1), so `xor eax,eax; ret` is a
#     correct stub. This matters: had it returned a float, clobbering only EAX
#     would have left XMM0 undefined and the caller would read garbage damage.
#   * the RVA is UNIQUE -- scanned all 31,282 types, exactly one owner. Detouring
#     or patching a SHARED RVA has unbounded blast radius (CLAUDE.md 5); this one
#     is safe on that axis.
#   * `EFT.LocalPlayer` derives DIRECTLY from `EFT.Player` and does NOT override
#     ApplyDamageInfo, so the local player's virtual dispatch lands on this
#     patched body. (`EFT.ClientPlayer`, a different branch via NetworkPlayer,
#     DOES override it at 0xAFFAC0 -- that one is remote players and is left
#     alone.) Which class the local player actually is at runtime was NOT
#     verified live; see adminDiag().
const GodDamageRva* = 0x731480'u32

var gRt: Il2Cpp
var gLive = false
var gStatus = "not attempted"
var gInRaid = false
var gLastCount = 0
var gLastSeen = 0

# ---- DRAW-STABILITY COUNTERS (task: the ESP FLICKER, CLAUDE.md 9b) ----------
# The position double-buffer's carry-forward bridges a per-PLAYER 1-sweep gap in
# the pos snapshot. It CANNOT touch a WHOLE-FRAME blank: every tick
# collectAndPublish reaches a bail that commits an empty frame (0 boxes) makes
# every box vanish for that tick regardless of how fresh the positions are. That
# is the flicker that survived the pos fix. These count each whole-frame outcome
# so the once-per-raid diag stops being unfalsifiable: a hold that "cannot fail"
# never moves gBlankNotAlive; a real regression makes it climb. The assertion to
# check LIVE is `gReached > 0 and gBoxed*k >= gReached` (nearly every projecting
# in-raid tick carried boxes) with gBlankNotAlive ~ 0 -- see dataDiag's
# "draw stable" line.
var gReached      = 0   ## ticks that reached the draw loop in-raid AND projecting
var gBoxed        = 0   ## ...of those, ticks that published >= 1 box
var gBlankNotAlive = 0  ## bailed: local player not found in AllAlivePlayersList
var gBlankOverlay = 0   ## bailed: an overlay/menu mask was open
var gBlankWorldNull = 0 ## bailed: GameWorld read null
var gBlankListNull = 0  ## bailed: player list null / out of range
var gLocalByIsYou = 0   ## times localAlive was rescued via IsYourPlayer because
                        ## GameWorld+0x230 (GwMainPlayer) read null this tick

var gRuntimeUp = false
var gWorldReady: WhenReady

# Every hop that did not validate, latched, so nothing declines silently.
var gDefect = ""
var gPosOk = false
var gStamOk = false
var gFaults = 0

# NO WEIGHT / NO RECOIL -- the FINISHED-STATE evidence, not the write's own
# return value (CLAUDE.md 9b). Each `apply*` reads, on the NEXT tick and BEFORE
# it writes again, the fields it wrote on the previous one:
#
#   gWtWrote / gRcWrote  -- a write was attempted at least once
#   gWtHeld  / gRcHeld   -- and the value was STILL applied when we looked back
#   gWtBroke / gRcBroke  -- the game had re-raised it between ticks
#
# Both counters can move in the same session; the diag reports the LAST
# observation, so "the toggle is on and the game is out-writing us" is a FAIL a
# reader can act on rather than a silent nothing. This check can fail -- that is
# the point of it. A check that only ever says yes is the bug.
var gWtWrote = false
var gWtHeld  = false
var gWtBroke = false
var gWtNote  = "not attempted"
var gRcWrote = false
var gRcHeld  = false
var gRcBroke = false
var gRcNote  = "not attempted"

const MaxFaults = 8   ## self-disable budget

proc note(msg: string) =
  ## First failing hop wins -- a later, downstream failure is a consequence, not
  ## the cause, and reporting the consequence sends the next reader the wrong way.
  if gDefect.len == 0: gDefect = msg

proc dataOpen*(): bool =
  if gLive: return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    gStatus = "GameAssembly not up yet"
    return false
  gLive = true
  # Declared here rather than at its var, because a nimony --app:lib global
  # initialised by a call/template is left zeroed.
  gWorldReady = whenReady("EFT.GameWorld")
  result = true

proc dataReady*(): bool =
  ## The gate that makes this file boot-safe. Until the game's assemblies are
  ## loaded (`EFT.GameWorld` resolves) NOTHING here touches game memory --
  ## poking around during il2cpp start-up is what faults the client.
  if not gLive: return false
  if gRuntimeUp: return true
  if ready(gWorldReady): gRuntimeUp = true
  result = gRuntimeUp

proc dataInRaid*(): bool = gInRaid
proc dataStatus*(): string = gStatus
proc dataLive*(): bool = gLive
proc dataDefectText*(): string =
  if gDefect.len == 0: "none" else: gDefect
proc dataFaults*(): int = gFaults
proc dataDisabled*(): bool = gFaults >= MaxFaults

proc espProjectable*(): bool =
  ## World->screen projection, from the camera view-projection snapshot the
  ## Unity-thread sampler publishes (`shared.camSample`, driven by admin.nim's
  ## everyMain). The single predicate the capability bit, the draw loop and
  ## adminDiag() all read, so they cannot drift apart.
  ##
  ## False is never "no enemies": `camStateText()` says which of not-bound,
  ## never-sampled, stale or self-disabled it is.
  camReady()

# ---------------------------------------------------------------------------
# The world, borrowed from the host's existing RegisterPlayer detour
# ---------------------------------------------------------------------------

proc overlayMaskOpen*(): bool =
  ## Returns whether a menu/settings overlay is open, so ESP can suppress itself
  ## mid-raid. Reads the host export `aowl_ui_overlay_mask` (uint32 bitmask;
  ## bit0=game Settings, bit1=F6, bit2=F3) per call; non-zero means an overlay
  ## is open. The single ESP call site is the `if overlayMaskOpen()` guard in
  ## collectAndPublish.
  hostUiOverlayMask() != 0'u32

proc worldPtr(): pointer =
  ## The live GameWorld. We do NOT install our own detour: a second detour on
  ## one function overwrites the first's trampoline and silently kills the first
  ## feature (CLAUDE.md 5). We read the host's cache instead.
  hostGameWorld()

# ---------------------------------------------------------------------------
# Guarded hops. Every read below goes through shared.nim's rd*, which
# VirtualQuery-checks the address first, so a stale offset is a zero, never a
# fault.
# ---------------------------------------------------------------------------

proc playerPos(p: pointer; ok: var bool; x, y, z: var float) =
  ## HOST THREAD. Reads back the snapshot `posSample()` published on Unity's
  ## thread. No game code runs here and no offset is walked: the finite/bounded/
  ## non-origin gates already ran inside `aowl_admin_pos_classify`, and an entry
  ## only exists at all if it passed them. False is "not in the last good
  ## sweep", never "the origin".
  ok = posGet(p, x, y, z)

proc playersList(world: pointer): pointer =
  ## AllAlivePlayersList (List<Player>, concrete) first; RegisteredPlayers
  ## (List<IPlayer>) as a fallback.
  result = rdPtr(world, GwAllAlivePlayers)
  if result == nil:
    result = rdPtr(world, GwRegisteredPlrs)

# ---------------------------------------------------------------------------
# The Unity-thread position sweep
# ---------------------------------------------------------------------------
#
# `EFT.Player::get_Position` @0x6F32C0 ends in `Transform::get_position_Injected`,
# a Unity native ICall, so it is legal ONLY on Unity's thread. `collectAndPublish`
# runs on the host's thread. That is the whole reason this is split: the sweep
# rides the same `everyMain` tick the camera sampler already rides (gated on the
# host confirming its main-thread drain has fired -- fact #136), and publishes a
# snapshot the host-thread pass reads with pure memory reads.

var gPosCode = posNoCall      ## the LAST exit reason the local-player sample took
var gPosSweeps = 0
var gPosGood = 0

# THE FALSIFIABLE ASSERTION (CLAUDE.md 9b). A finite, bounded, non-origin
# position that NEVER CHANGES is exactly what a wrong-but-plausible offset
# produces, and it would pass every gate above. So the local player's position
# is compared against the previous sweep's and the largest displacement ever
# seen is kept. `gPosMoved` is the only thing that can turn `positions` into a
# PASS, and standing still makes it INCONCLUSIVE -- not a pass.
var gPosHavePrev = false
var gPosPx = 0.0
var gPosPy = 0.0
var gPosPz = 0.0
var gPosMaxStep = 0.0
var gPosMoved = false

proc posSample*() =
  ## UNITY THREAD ONLY. One sweep per frame: arm (once), walk the player list,
  ## sample each, publish. Capped, allocation-free, and a no-op until the world
  ## and the prologue are both good.
  if not gLive or not dataReady() or dataDisabled(): return
  # L2 BRACKETS. Every one of these wraps a call site that already existed;
  # nothing here changes what runs or in what order. They sit outside any
  # aowl_p_p_seh (that guard is not re-entrant) and are no-ops when the
  # profiler is off.
  let tArm = apNow()
  let armed = posArm()
  apAdd(ApPArm, tArm)
  if armed != 1:
    gPosCode = posNoCall
    if armed < 0:
      note("EFT.Player::get_Position @0x6F32C0 prologue did NOT byte-verify " &
           "against this build -- position sampling REFUSED, permanently")
    return
  let tWorld = apNow()
  let world = worldPtr()
  if world == nil:
    apAdd(ApPWorld, tWorld)
    return

  let list = playersList(world)
  if list == nil:
    apAdd(ApPWorld, tWorld)
    return
  let items = rdPtr(list, ListItemsOff)
  var n = int(rdI32(list, ListSizeOff))
  let me = rdPtr(world, GwMainPlayer)
  apAdd(ApPWorld, tWorld)
  if items == nil or n < 0 or n > 1024: return

  gPosSweeps = gPosSweeps + 1
  posBegin()
  var good = 0
  if me != nil:
    let tMe = apNow()
    let c = posAdd(me)
    apAdd(ApPMe, tMe)
    gPosCode = c
    if c == posOk: good = good + 1
  let tLoop = apNow()
  var i = 0
  while i < n:
    let tF = apNow()
    let p = rdPtr(items, ArrDataOff + i*8)
    apAdd(ApEFetch, tF)
    inc i
    if p == nil or p == me: continue
    let tA = apNow()
    let code = posAdd(p)
    apAdd(ApEAdd, tA)
    if code == posOk: good = good + 1
  apAdd(ApPLoop, tLoop)
  let tCommit = apNow()
  posCommit()
  apAdd(ApPCommit, tCommit)
  if good > 0: gPosGood = gPosGood + 1

  # The movement check, taken on the FINISHED published snapshot.
  let tMove = apNow()
  if me != nil:
    var x = 0.0; var y = 0.0; var z = 0.0
    if posGet(me, x, y, z):
      gPosOk = true
      if gPosHavePrev:
        let dx = x - gPosPx; let dy = y - gPosPy; let dz = z - gPosPz
        let step = dx*dx + dy*dy + dz*dz
        if step > gPosMaxStep: gPosMaxStep = step
        if step > 1.0e-6: gPosMoved = true
      gPosPx = x; gPosPy = y; gPosPz = z
      gPosHavePrev = true
    elif gPosCode != posOk:
      note("player position: " & posCodeText(gPosCode))
  apAdd(ApPMove, tMove)

proc distance(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx; let dy = ay - by; let dz = az - bz
  var d2 = dx*dx + dy*dy + dz*dz
  if d2 <= 0.0: return 0.0
  var d = d2
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d); inc k
  result = d

# ---------------------------------------------------------------------------
# Faction, read from the REAL side field, not inferred from "is a bot".
# ---------------------------------------------------------------------------

# EPlayerSide literals, MEASURED from EFT.EPlayerSide:
#     Usec = 1, Bear = 2, Savage = 4   (3 is unused -- note it is NOT 3).
# PMC is Usec|Bear; scav is Savage.
const
  SideUsec   = 1'i32
  SideBear   = 2'i32
  SideSavage = 4'i32

# WildSpawnType (EFT.WildSpawnType) literals used to refine a Savage into
# scav / boss / raider / rogue. MEASURED from the enum's own constants
# (`python tools/il2cpp_resolve.py ... fields WildSpawnType`). Only the values
# that change the LABEL are named; everything else on the Savage side is an
# ordinary scav.
const
  RoleRaider = 9'i32    ## pmcBot -- Raiders
  RoleRogue  = 24'i32   ## exUsec -- Rogues
  BossRoles  = [2'i32, 3, 6, 7, 11, 17, 20, 21, 22, 26, 29, 32, 36, 43, 47]
                        ## bossTest,bossBully,bossKilla,bossKojaniy,bossGluhar,
                        ## bossSanitar,sectantWarrior,sectantPriest,bossTagilla,
                        ## bossKnight,bossZryachiy,bossBoar,bossBoarSniper,
                        ## bossKolontay,bossPartisan

proc isBossRole(r: int32): bool =
  for b in BossRoles:
    if b == r: return true
  false

proc factionOf(p: pointer): tuple[side: int32, label: string] =
  ## The REAL faction, read Player -> Profile -> Info -> Side (EPlayerSide),
  ## refining Savage via Settings.Role (WildSpawnType). Every hop is guarded
  ## (rdPtr/rdI32 VirtualQuery first), so a stale offset or moved object is a
  ## zero, never a fault. An UNREADABLE or genuinely-zero side returns
  ## sideUnknown -- it does NOT fall back to scav. That is the whole point of
  ## the fix (CLAUDE.md 9b): the previous code could only ever say scav for a
  ## bot; this one distinguishes USEC/BEAR/scav/boss/raider/rogue AND can say
  ## "unknown", so it is falsifiable.
  result = (sideUnknown, "?")
  let prof = rdPtr(p, PlProfile)
  if prof == nil: return
  let info = rdPtr(prof, ProfInfo)
  if info == nil: return
  let side = rdI32(info, PInfoSide)
  case side
  of SideUsec: return (sideEnemy, "USEC")
  of SideBear: return (sideEnemy, "BEAR")
  of SideSavage:
    var role = -1'i32
    let settings = rdPtr(info, PInfoSettings)
    if settings != nil: role = rdI32(settings, PSettingsRole)
    if isBossRole(role): return (sideBoss, "Boss")
    if role == RoleRaider: return (sideBoss, "Raider")
    if role == RoleRogue:  return (sideBoss, "Rogue")
    return (sideScav, "Scav")
  else: return (sideUnknown, "?")

proc dataResolved*(): bool =
  ## ESP is live only when there is a world, a validated position read, AND a
  ## way to put a pixel on the screen. Drives the ESP capability bit, so the HUD
  ## never offers a mode that cannot draw.
  gLive and gInRaid and gPosOk and espProjectable() and not dataDisabled()

proc collectAndPublish*(s: AdminRegion; maxDistance: float; bbW, bbH: int) =
  if not gLive:
    setInRaid(s, false); return
  if dataDisabled():
    setInRaid(s, false)
    gStatus = "self-disabled after " & $gFaults & " faults: " & dataDefectText()
    return
  if not dataReady():
    setInRaid(s, false)
    gStatus = "runtime not ready yet (waiting for game assemblies)"
    return

  let world = worldPtr()
  gInRaid = (world != nil)
  setInRaid(s, gInRaid)
  if world == nil:
    gBlankWorldNull = gBlankWorldNull + 1
    gStatus = "no GameWorld: " & gwStateText()
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # Local player, for distance + skipping self.
  var lx = 0.0; var ly = 0.0; var lz = 0.0
  var haveLocal = false
  var localPtr = 0'u64
  let me = rdPtr(world, GwMainPlayer)
  if me != nil:
    localPtr = cast[uint64](me)
    # gPosOk is NOT set here: it is owned by posSample() on Unity's thread,
    # which is the only place a position is actually produced. Setting it from
    # a snapshot read would make it a restatement of our own cache.
    playerPos(me, haveLocal, lx, ly, lz)
  else:
    note("GameWorld+0x230 MainPlayer read null")

  # STABILISE THE DISTANCE CULL against a transient this frame. If GwMainPlayer
  # read null (or its snapshot was not published yet) we have no local position,
  # `haveLocal` is false, the `maxDistance` cull below is skipped, and every
  # distant bot suddenly draws -- then vanishes next frame when the pointer
  # returns. That inconsistency is remote boxes BLINKING WITH THE LOCAL PLAYER'S
  # OWN STATE (task 2b). posSample() publishes the last good local world position
  # (gPosPx/Py/Pz, set only from a validated sample of `me`); fall back to it so
  # the cull stays steady. A frame-stale, already-validated position -- never
  # fabricated, and the box positions themselves are unaffected (they use each
  # target's own sample). Only the local anchor for the distance test is filled.
  if not haveLocal and gPosHavePrev:
    lx = gPosPx; ly = gPosPy; lz = gPosPz; haveLocal = true

  let list = playersList(world)
  if list == nil:
    note("GameWorld player list (+0x1C8 / +0x1D0) read null")
    gStatus = "GameWorld live but the player list read null"
    frameBegin(s, bbW, bbH); frameCommit(s); return
  let items = rdPtr(list, ListItemsOff)
  var n = int(rdI32(list, ListSizeOff))
  # Capped iteration: a corrupt count must not become an unbounded loop inside a
  # frame. 1024 is far above any real raid population.
  if items == nil or n < 0 or n > 1024:
    gBlankListNull = gBlankListNull + 1
    note("player list size out of range (" & $n & ")")
    gStatus = "player list empty/out of range (" & $n & ")"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # LIFECYCLE GATE (task 3), mirrored from the maps mod's activeRaid()
  # (mods/maps/sp/world.nim, commit d10c95d on fix-maps-lifecycle). The borrowed
  # RegisterPlayer cache makes `world` non-null in the menu, during loading
  # BEFORE the player spawns, and after extract (fact #141: whenReady(
  # "EFT.GameWorld") goes true ~47ms after boot with NO raid). LocationId can
  # likewise be answered from a stale cache, which is why maps uses it only to
  # SELECT the map and NOT as the gate. The signal that goes false the instant
  # the local player is not a spawned participant is membership in the LIVE
  # AllAlivePlayersList -- the game's own "spawned and in-world" set. Require it
  # before drawing, and idle (an empty committed frame -> 0 boxes) when absent,
  # so ESP never draws in menu / loading / post-extract. `localPtr` is 0 when
  # GameWorld+0x230 read null, in which case we cannot prove we are spawned and
  # correctly treat it as not-in-raid rather than guessing.
  # ROBUST LIFECYCLE GATE (task: the ESP FLICKER that survived the pos fix).
  # Identifying WHICH list entry is us must NOT depend on GameWorld+0x230
  # (GwMainPlayer): it reads null intermittently on this build -- the very
  # transient the self-box and distance-cull guards above already exist for. When
  # it does, `localPtr` is 0, no entry matched the OLD `if localPtr != 0` scan,
  # `localAlive` went false, and the WHOLE frame committed empty -- every box
  # vanished for that one tick. The position carry-forward cannot bridge a
  # whole-frame blank, which is why the flicker persisted. IsYourPlayer
  # (Player+0xB89) is true only on the local instance and never depends on
  # GwMainPlayer (see PlIsYou's note), so it identifies us on every frame. Scan
  # once: an entry is us if it equals `localPtr` OR reads IsYou==1. When
  # GwMainPlayer gave nothing this tick, adopt our own list entry as `localPtr`
  # (for the draw loop's self-exclusion) and take the distance anchor from its
  # validated snapshot, so a null GwMainPlayer no longer blanks the frame.
  var localAlive = false
  var j = 0
  while j < n:
    let q = rdPtr(items, ArrDataOff + j*8)
    inc j
    if q == nil: continue
    if (localPtr != 0'u64 and cast[uint64](q) == localPtr) or
       rdBool(q, PlIsYou) == 1'i32:
      localAlive = true
      if localPtr == 0'u64:
        localPtr = cast[uint64](q)
        gLocalByIsYou = gLocalByIsYou + 1
        if not haveLocal:
          playerPos(q, haveLocal, lx, ly, lz)
      break
  gInRaid = localAlive
  setInRaid(s, gInRaid)
  if not localAlive:
    gBlankNotAlive = gBlankNotAlive + 1
    gStatus = "world live but the local player is NOT in AllAlivePlayersList -- " &
              "menu, loading-before-spawn, or post-extract, not an active raid"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # OVERLAY-MASK SUPPRESSION HOOK. `overlayMaskOpen()` reads the host export
  # `aowl_ui_overlay_mask` (uint32 bitmask; bit0=game Settings open, bit1=F6,
  # bit2=F3), so ESP hides while a menu/settings screen is open mid-raid. The
  # single suppression point is the next two lines.
  if overlayMaskOpen():
    gBlankOverlay = gBlankOverlay + 1
    gStatus = "in raid, but an overlay/menu mask is open -- ESP suppressed"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  frameBegin(s, bbW, bbH)
  # Snapshotted ONCE per frame, not per entity: the Unity-thread sampler can
  # flip readiness mid-loop, and half a frame of boxes is a worse artifact than
  # a whole frame of none.
  let projecting = espProjectable()
  var published = 0
  var seen = 0
  var i = 0
  while i < n:
    let p = rdPtr(items, ArrDataOff + i*8)
    inc i
    if p == nil or cast[uint64](p) == localPtr: continue
    # ROBUST self-exclusion. The pointer test above misses self on any frame
    # where GameWorld+0x230 (GwMainPlayer) read null -- localPtr is then 0, no
    # list entry equals it, and the LOCAL player gets a box. Intermittent null
    # reads are exactly the "glitching in and out from me being visible" the
    # user saw: the box on SELF, blinking as the pointer came and went.
    # `IsYourPlayer` is true only on the local instance and never depends on
    # that pointer, so it excludes self on every frame. rdBool is guarded
    # (VirtualQuery first): a stale offset reads -1, never a fault, and only a
    # definite 1 excludes -- an unreadable value is NOT treated as self.
    if rdBool(p, PlIsYou) == 1'i32: continue
    var pok = false
    var hx = 0.0; var hy = 0.0; var hz = 0.0
    playerPos(p, pok, hx, hy, hz)
    if not pok: continue
    inc seen

    var dist = 0.0
    if haveLocal:
      dist = distance(hx, hy, hz, lx, ly, lz)
      if maxDistance > 0.0 and dist > maxDistance: continue

    # AIData still tags the entity as AI for the overlay's flag, but it NO
    # LONGER decides the side/label -- that is the check that could only ever
    # say scav (task 1). The side is the REAL faction, read from the Profile.
    var flags = 0'u32
    if rdPtr(p, PlAIData) != nil:
      flags = flags or flagIsAI
    let fac = factionOf(p)
    let side = fac.side

    if projecting:
      # The box: feet at the validated world position, head one standing height
      # above it. Both ends are projected; if EITHER fails the entity is behind
      # the camera or off the frustum and is dropped, rather than drawn at a
      # clamped edge -- a box pinned to the screen edge for someone behind you
      # is worse than no box.
      var bx = 0.0; var by = 0.0
      var tx = 0.0; var ty = 0.0
      if not worldToScreen(hx, hy, hz, bbW, bbH, bx, by): continue
      if not worldToScreen(hx, hy + PlayerHeightM, hz, bbW, bbH, tx, ty):
        continue
      # A property of the FINISHED projection, not of the call: a degenerate or
      # inverted box means the matrix or the position is wrong, and drawing it
      # would put a plausible-looking artifact on screen.
      if bx != bx or by != by or tx != tx or ty != ty: continue
      if by <= ty: continue
      if (by - ty) < 1.0 or (by - ty) > float(bbH) * 4.0: continue
      let cx = 0.5 * (bx + tx)
      if cx < float(-bbW) or cx > float(bbW * 2): continue
      flags = flags or flagOnScreen
      frameAdd(s, cx, ty, by, -1.0, -1.0, dist, side, flags, fac.label)
      published = published + 1
  gLastCount = published
  gLastSeen = seen
  if projecting:
    # Whole-frame draw-stability tally. `gReached` counts every projecting
    # in-raid commit; `gBoxed` the subset that carried >=1 box. The falsifiable
    # assertion (CLAUDE.md 9b) is that once we are in-raid-projecting with enemies
    # present, gBoxed tracks gReached -- a large gap means frames are blanking,
    # and the gBlank*/gLocalByIsYou counters say which gate. `seen > 0` scopes it
    # to ticks where at least one other player position validated, so a genuine
    # all-behind-camera moment does not read as a flicker.
    if seen > 0:
      gReached = gReached + 1
      if published > 0: gBoxed = gBoxed + 1
  frameCommit(s)
  if projecting:
    gStatus = "in raid; boxed " & $published & " of " & $seen &
              " players (" & $n & " in the list)"
    if seen > 0 and published == 0:
      # Not an error -- everyone can genuinely be behind you -- but it is the
      # exact shape of "the matrix is wrong", so it must not read as success.
      gStatus.add "; every one of them projected OFF-SCREEN or behind the " &
                  "camera, which is also what a bad view-projection looks like"
  else:
    gStatus = "in raid; " & $seen & " of " & $n & " player positions VALIDATED, " &
              "but no boxes drawn -- world->screen: " & camStateText()

proc espSeen*(): int = gLastSeen
proc espBoxed*(): int = gLastCount

# ---------------------------------------------------------------------------
# God mode -- the static byte-patch. Works from any thread, needs no world.
# ---------------------------------------------------------------------------

proc godCapable*(): bool = gameAssemblyPresent()

proc setGodmode*(on: bool) =
  ## Apply/revert the ApplyDamageInfo byte-patch. Idempotent. The C side
  ## byte-verifies the exact 5-byte prologue before writing and REFUSES on a
  ## mismatch, so a future build is a no-op rather than a corruption.
  if not gameAssemblyPresent(): return
  if on and not godmodePatch(true, GodDamageRva):
    note("ApplyDamageInfo @0x731480 prologue did not verify -- god mode REFUSED")
    return
  if not on: discard godmodePatch(false, GodDamageRva)

proc godStatus*(): string =
  ## Reports the FINISHED state (is the patch actually installed) rather than
  ## "we asked for it", and names the scope, because "god=ON" while bots are
  ## also invulnerable is a materially different thing than the player expects.
  if godmodeIsOn(): "god=ON (EFT.Player::ApplyDamageInfo patched; GLOBAL -- " &
                    "bots are invulnerable too)"
  else: "god=off"

# ---------------------------------------------------------------------------
# Infinite stamina -- PhysicalBase.Stamina.Current <- PhysicalBase.StaminaCapacity
# ---------------------------------------------------------------------------

proc staminaCapable*(): bool =
  gLive and gInRaid and gStamOk and not dataDisabled()

proc applyStamina*() =
  if not gLive or not dataReady() or dataDisabled(): return
  let world = worldPtr()
  if world == nil: return
  let me = rdPtr(world, GwMainPlayer)
  if me == nil: return
  let phys = rdPtr(me, PlPhysical)
  if phys == nil:
    note("Player+0x9D8 Physical read null"); return
  let stam = rdPtr(phys, PhStamina)
  if stam == nil:
    note("PhysicalBase+0x68 Stamina read null"); return
  # The true max is PhysicalBase.StaminaCapacity (a float). Stamina.TotalCapacity
  # is a Compute<float> REFERENCE -- reading it as a float and writing the result
  # back, as this used to, is a blind write of half a pointer.
  let maxVal = rdF32(phys, PhStaminaCapacity)
  # Validate the value we are about to write, not the write itself.
  if maxVal != maxVal or maxVal <= 0.0 or maxVal > 1.0e5:
    note("PhysicalBase+0x8C StaminaCapacity implausible; stamina write REFUSED")
    return
  gStamOk = true
  wrF32(stam, StCurrent, maxVal)

# ---------------------------------------------------------------------------
# No weight -- PhysicalBase's four overweight floats and two encumbrance bools
# ---------------------------------------------------------------------------

proc physPtr(): pointer =
  ## The local player's PhysicalBase, every hop validated. Shared by the stamina
  ## write and the two below so there is ONE chain to be wrong, not three.
  ## `cast[pointer](0)`, not `nil`: nimony refuses a bare nil literal on the
  ## right of an assignment ("expected non-nil value").
  result = cast[pointer](0)
  if not gLive or not dataReady() or dataDisabled(): return
  let world = worldPtr()
  if world == nil: return
  let me = rdPtr(world, GwMainPlayer)
  if me == nil: return
  let phys = rdPtr(me, PlPhysical)
  if phys == nil:
    note("Player+0x9D8 Physical read null"); return
  result = phys

proc noWeightCapable*(): bool =
  ## Capability is "a write has been attempted and the object read back sanely",
  ## never "the offsets compile". Drives the region capability bit, so the F6
  ## menu cannot offer a hotkey for something that is not writing.
  gLive and gInRaid and gWtWrote and not dataDisabled()

proc applyNoWeight*() =
  let phys = physPtr()
  if phys == nil: return

  # --- look BACK first. This reads what the previous tick wrote, before this
  # tick overwrites it, so it is an observation of the finished state and not a
  # readback of our own store. If the game re-raised Overweight in between, this
  # is where that shows up.
  if gWtWrote:
    let ow  = rdF32(phys, PhOverweight)
    let enc = rdBool(phys, PhEncumbered)
    if enc < 0:
      gWtNote = "PhysicalBase+0x11C not readable on the look-back"
    elif ow == 0.0 and enc == 0'i32:
      gWtHeld = true; gWtBroke = false
      gWtNote = "Overweight and _encumbered were still 0 on the next tick"
    else:
      gWtHeld = false; gWtBroke = true
      gWtNote = "the game re-raised Overweight between ticks (read back " &
                "non-zero), so the suppression is not holding"

  # --- validate before writing. `Overweight` is a ratio the movement code
  # divides by; a wild value here means the offset is not this field on this
  # build, and writing into it anyway is the blind write rule 8 forbids.
  let cur = rdF32(phys, PhOverweight)
  if cur != cur or cur < -1.0e3 or cur > 1.0e3:
    note("PhysicalBase+0x1C Overweight implausible (" & $cur &
         "); no-weight write REFUSED")
    return
  if rdBool(phys, PhEncumbered) < 0'i32:
    note("PhysicalBase+0x11C _encumbered not readable; no-weight write REFUSED")
    return

  wrF32(phys, PhOverweight, 0.0)
  wrF32(phys, PhWalkOverweight, 0.0)
  wrF32(phys, PhSprintOverweight, 0.0)
  # WalkSpeedLimit is a CAP, not a penalty: 0 would pin the player still. 1.0 is
  # "no limit" in the same units the four ratios above use.
  wrF32(phys, PhWalkSpeedLimit, 1.0)
  discard wrBool(phys, PhEncumbered, false)
  discard wrBool(phys, PhOverEncumbered, false)
  gWtWrote = true

# ---------------------------------------------------------------------------
# No recoil / sway -- the recoil pipeline's own switch, plus the sway inputs
# ---------------------------------------------------------------------------

proc pwAnimPtr(): pointer =
  result = cast[pointer](0)
  if not gLive or not dataReady() or dataDisabled(): return
  let world = worldPtr()
  if world == nil: return
  let me = rdPtr(world, GwMainPlayer)
  if me == nil: return
  let pw = rdPtr(me, PlPwAnim)
  if pw == nil:
    note("Player+0x3C0 ProceduralWeaponAnimation read null"); return
  result = pw

proc noRecoilCapable*(): bool =
  gLive and gInRaid and gRcWrote and not dataDisabled()

proc applyNoRecoil*() =
  let pw = pwAnimPtr()
  if pw == nil: return
  let shoot = rdPtr(pw, PwShootingg)
  if shoot == nil:
    gRcNote = "ProceduralWeaponAnimation+0x70 Shootingg read null -- no weapon " &
              "in hands yet"
    # NOT a defect: with empty hands there is no ShotEffector to switch off. The
    # sway half below still applies, so this returns only after doing that.
    discard
  var nr = cast[pointer](0)
  if shoot != nil:
    nr = rdPtr(shoot, SeNewShotRecoil)
    if nr == nil:
      gRcNote = "ShotEffector+0x20 NewShotRecoil read null (this weapon may be " &
                "on the OLD recoil pipeline, which this row does not touch)"

  # --- look back, before overwriting. RecoilEffectOn is re-set by the game on a
  # weapon change, and this is what makes that visible instead of silent.
  # A stale PASS is the trap here: with no weapon in hands `nr` is nil, there is
  # nothing to look back AT, and leaving gRcHeld set from an earlier tick would
  # let the diag keep reporting PASS for a suppression nobody can observe. Clear
  # both verdicts so that case reads INCONCLUSIVE with the reason attached.
  if gRcWrote and nr == nil:
    gRcHeld = false; gRcBroke = false
  if gRcWrote and nr != nil:
    let on = rdBool(nr, NrRecoilEffectOn)
    if on < 0:
      gRcNote = "NewRecoilShotEffect+0x11 not readable on the look-back"
    elif on == 0'i32:
      gRcHeld = true; gRcBroke = false
      gRcNote = "RecoilEffectOn was still 0 on the next tick"
    else:
      gRcHeld = false; gRcBroke = true
      gRcNote = "the game re-enabled RecoilEffectOn between ticks (a weapon " &
                "change does this); it is re-suppressed each tick"

  if nr != nil:
    # Validate: a bool byte is 0 or 1. Anything else means +0x11 is not this
    # field on this build, and the write is refused rather than smeared over
    # whatever is really there.
    let on = rdBool(nr, NrRecoilEffectOn)
    if on != 0'i32 and on != 1'i32:
      note("NewRecoilShotEffect+0x11 RecoilEffectOn read " & $on &
           ", which is not a bool; no-recoil write REFUSED")
      return
    if wrBool(nr, NrRecoilEffectOn, false):
      gRcWrote = true

  # Sway: four floats on the animation object itself. Zeroing the two Vector3
  # limits and the two scalars removes the aim-sway input; it does not touch the
  # code that consumes them.
  let sf = rdF32(pw, PwSwayFactor)
  if sf != sf or sf < -1.0e4 or sf > 1.0e4:
    note("ProceduralWeaponAnimation+0x4A4 _swayFactor implausible; sway write " &
         "REFUSED")
    return
  wrF32(pw, PwSwayStrength, 0.0)
  wrF32(pw, PwSwayFactor, 0.0)
  wrF32(pw, PwAimSwayMax + 0, 0.0)
  wrF32(pw, PwAimSwayMax + 4, 0.0)
  wrF32(pw, PwAimSwayMax + 8, 0.0)
  wrF32(pw, PwAimSwayMin + 0, 0.0)
  wrF32(pw, PwAimSwayMin + 4, 0.0)
  wrF32(pw, PwAimSwayMin + 8, 0.0)
  gRcWrote = true

# ---------------------------------------------------------------------------
# Diagnostics -- what bound, what did not, and WHY. Three outcomes, never two.
# ---------------------------------------------------------------------------

proc dataDiag*(): string =
  ## PASS / FAIL / INCONCLUSIVE per capability. "I could not look" is never a
  ## pass: outside a raid there is nothing to read, and that is INCONCLUSIVE,
  ## not a failure of the offsets.
  var r = ""
  r.add "  runtime      : " & (if not gLive: "FAIL  GameAssembly not open"
                               elif not gRuntimeUp: "INCONCLUSIVE  assemblies not up yet"
                               else: "PASS  il2cpp up") & "\n"
  r.add "  gameworld    : " & (if worldPtr() != nil: "PASS  " else:
                               (if gwState() <= 1: "FAIL  " else: "INCONCLUSIVE  ")) &
        gwStateText() & "\n"
  # POSITIONS. PASS requires the FINISHED STATE, not our own read: finite,
  # bounded, non-origin AND OBSERVED TO CHANGE. A static non-zero value is what
  # a wrong-but-plausible offset produces and it is NOT a pass -- standing still
  # is INCONCLUSIVE. Every failure names WHICH of the exit reasons it took.
  r.add "  positions    : " &
        (if posArmed() < 0:
           "FAIL  EFT.Player::get_Position @0x6F32C0 prologue did not " &
           "byte-verify against this build"
         elif not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gPosSweeps == 0:
           "INCONCLUSIVE  the Unity-thread sweep has never fired (see esp " &
           "sampler) -- get_position_Injected cannot be called from the host " &
           "thread, so nothing has been sampled"
         elif not gPosOk:
           "FAIL  " & $gPosSweeps & " sweeps, no local position: " &
           posCodeText(gPosCode)
         elif gPosMoved:
           "PASS  EFT.Player::get_Position @0x6F32C0 via Player+0xB40->" &
           "PlayerBones+0x178->BifacialTransform; " & $posCount() &
           " in snapshot gen " & $posGen() & ", and the local position HAS " &
           "CHANGED between sweeps"
         else:
           "INCONCLUSIVE  " & $posCount() & " positions validated but the " &
           "local one has NOT changed across " & $gPosSweeps & " sweeps -- " &
           "either the player is standing still, or this is a plausible " &
           "constant rather than a live pose. Move and re-run") & "\n"
  r.add "  pos reasons  : " &
        ("ok=" & $posStat(posOk) & " nilBones=" & $posStat(posNilBones) &
         " nilXform=" & $posStat(posNilXform) & " imitated=" &
         $posStat(posImitated) & " allZero=" & $posStat(posAllZero) &
         " nan=" & $posStat(posNan) & " range=" & $posStat(posRange) &
         " noCall=" & $posStat(posNoCall)) & "\n"
  # The projection is a SEPARATE axis from the raid: it binds and samples in the
  # menu too. So a bind failure is FAIL wherever it happens, "bound but never
  # sampled / stale" is INCONCLUSIVE, and only a live snapshot is PASS. None of
  # the three is ever reported as "not in a raid".
  r.add "  esp project  : " &
        (if camState() == 2: "FAIL  " & camStateText()
         elif camDisabled(): "FAIL  " & camStateText()
         elif camReady(): "PASS  view-projection " & camStateText()
         else: "INCONCLUSIVE  " & camStateText()) & "\n"
  r.add "  esp draw     : " &
        (if not camReady(): "INCONCLUSIVE  cannot draw without a projection " &
                            "(see the line above)"
         elif not gInRaid: "INCONCLUSIVE  no raid, nothing to box"
         elif gLastSeen == 0: "INCONCLUSIVE  projection live but no other " &
                              "player position validated this frame"
         elif gLastCount > 0: "PASS  " & $gLastCount & " of " & $gLastSeen &
                              " boxed on the last frame"
         else: "INCONCLUSIVE  " & $gLastSeen & " positions validated, 0 " &
               "projected on screen -- everyone behind the camera, or the " &
               "view-projection is wrong") & "\n"
  # DRAW STABILITY (task: the ESP FLICKER). The whole-frame outcome tally the
  # once-per-raid diag lacked. A PASS asserts the FINISHED STATE, not our write:
  # of the projecting in-raid ticks that saw >=1 other player, (nearly) all
  # carried boxes, and the whole-frame blank that GwMainPlayer-null used to cause
  # (gBlankNotAlive) did not climb. It is falsifiable -- gBlankNotAlive CAN move,
  # so a flicker that persists shows here instead of hiding.
  r.add "  draw stable  : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing drawn"
         elif gReached == 0: "INCONCLUSIVE  no projecting in-raid tick has seen " &
              "another player yet"
         elif gBoxed * 20 >= gReached * 19 and gBlankNotAlive == 0:
              "PASS  boxed " & $gBoxed & " of " & $gReached &
              " projecting ticks; 0 whole-frame blanks from a null GwMainPlayer" &
              (if gLocalByIsYou > 0: " (IsYou rescued " & $gLocalByIsYou &
                 " tick(s) where GameWorld+0x230 read null)" else: "")
         else: "FAIL  boxed only " & $gBoxed & " of " & $gReached &
              " projecting ticks; whole-frame blanks: notAlive=" &
              $gBlankNotAlive & " overlay=" & $gBlankOverlay & " worldNull=" &
              $gBlankWorldNull & " listNull=" & $gBlankListNull &
              " (IsYou rescues=" & $gLocalByIsYou & ")") & "\n"
  r.add "  god mode     : " &
        (if not godCapable(): "FAIL  GameAssembly.dll not present"
         elif godmodeIsOn(): "PASS  patch installed at 0x731480"
         elif not gInRaid: "INCONCLUSIVE  deferred to in-raid; not patched outside one"
         else: "INCONCLUSIVE  in raid but toggle off") & "\n"
  r.add "  stamina      : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gStamOk: "PASS  PhysicalBase+0x8C -> Stamina+0x10 written"
         else: "INCONCLUSIVE  not attempted or capacity implausible") & "\n"
  # NO WEIGHT / NO RECOIL. PASS is granted ONLY by the look-back -- a read taken
  # on a later tick, before the next write, of the state the previous write left
  # behind. "We wrote it" is INCONCLUSIVE, never PASS, and the game winning the
  # race is a FAIL that says so.
  r.add "  no weight    : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to write"
         elif not gWtWrote: "INCONCLUSIVE  toggle off, or the write was refused" &
                            " -- " & gWtNote
         elif gWtBroke: "FAIL  " & gWtNote
         elif gWtHeld: "PASS  PhysicalBase 0x1C/0x20/0xD0/0x24 + 0x11C/0x11D; " &
                       gWtNote
         else: "INCONCLUSIVE  written once, but no look-back tick yet") & "\n"
  r.add "  no recoil    : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to write"
         elif not gRcWrote: "INCONCLUSIVE  toggle off, or nothing to write -- " &
                            gRcNote
         elif gRcBroke: "FAIL  " & gRcNote
         elif gRcHeld: "PASS  NewRecoilShotEffect+0x11 off + sway zeroed; " &
                       gRcNote
         else: "INCONCLUSIVE  written once, but no look-back tick yet") & "\n"
  r.add "  faults       : " & $gFaults & " of " & $MaxFaults &
        (if dataDisabled(): "  SELF-DISABLED" else: "") & "\n"
  r.add "  first defect : " & dataDefectText()
  result = r
