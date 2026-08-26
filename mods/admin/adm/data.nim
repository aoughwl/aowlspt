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

  # EFT.MovementContext
  McPreviousPosition = 0x370  ## Vector3 -- the real world position

  # PhysicalBase
  PhStamina         = 0x68    ## Stamina
  PhStaminaCapacity = 0x8C    ## float -- the true max (NOT Stamina.TotalCapacity,
                              ## which is a Compute<float> reference)

  # Stamina
  StCurrent         = 0x10    ## float

  # ---- ADDED 2026-08-26, all from tools/fldoff.py against this build ------
  # Every one printed by `python tools/fldoff.py fields <Type>`, which refuses
  # to print anything until its own self-check (System.String._stringLength
  # @0x10, _firstChar@0x14) passes. None is inferred from a name.

  # EFT.Player
  PlProfile         = 0x9C0   ## Profile
  # EFT.Profile
  PrInfo            = 0x48    ## ProfileInfo
  # EFT.ProfileInfo
  PiNickname        = 0x10    ## string
  PiSide            = 0x48    ## EPlayerSide (int32)

  # EFT.MovementContext -- the two speed caps the client itself reads.
  McMaxSpeed        = 0x37C   ## float  <MaxSpeed>k__BackingField
  McSprintSpeed     = 0x380   ## float  <SprintingSpeed>k__BackingField

  # EFT.GameWorld -- loose loot and the clock.
  GwLootList        = 0x1B0   ## List<IKillable>  (the live loot objects)
  GwGameDateTime    = 0xF0    ## GameDateTime
  # EFT.GameDateTime
  GdtStatedGameTime = 0x20    ## DateTime (a struct: one int64 of ticks+kind)
  GdtTimeFactor     = 0x28    ## float
  GdtLocked         = 0x34    ## bool

  # EFT.Interactive.LootItem
  LiName            = 0x68    ## string   (the localised-ish display name)
  LiItemId          = 0x78    ## string
  LiStartPosition   = 0x10C   ## Vector3

## `EPlayerSide` as the client declares it. Used only to COLOUR a box; a value
## outside this set colours the box "unknown" rather than being forced into one
## of them, because a forced guess is exactly the confidently-wrong answer this
## project keeps paying for.
const
  SideUsec   = 1'i32
  SideBear   = 2'i32
  SideSavage = 4'i32

## Loot markers are drawn as a small fixed-height box. This is a DRAWING
## constant (the HUD needs a top and a bottom), not a measured item size, and it
## is deliberately not dressed up as one.
const LootMarkerPx = 8.0

## Box height. The position read at MovementContext+0x370 is the player ROOT
## (feet), so the head is one standing height above it. 1.8 m is a drawing
## constant, NOT a measured field -- it is deliberately not dressed up as one.
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
var gRuntimeUp = false
var gWorldReady: WhenReady

# Every hop that did not validate, latched, so nothing declines silently.
var gDefect = ""
var gPosOk = false
var gStamOk = false
var gSideOk = false
var gNameOk = false
var gLootSeen = 0
var gLootBoxed = 0
var gLootNamed = 0
var gLootListLen = 0
var gFaults = 0

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
  ## Player +0x60 -> MovementContext +0x370 (Vector3). The same chain the host's
  ## own working ESP walks, and the pose the client itself reads.
  ok = false
  x = 0.0; y = 0.0; z = 0.0
  if p == nil: return
  let mc = rdPtr(p, PlMovementContext)
  if mc == nil:
    note("Player+0x60 MovementContext read null")
    return
  x = rdF32(mc, McPreviousPosition + 0)
  y = rdF32(mc, McPreviousPosition + 4)
  z = rdF32(mc, McPreviousPosition + 8)
  # A position is finite and inside any Tarkov map by a wide margin. This is a
  # property of the FINISHED read, not a restatement of it: garbage from a moved
  # object or a stale offset fails it.
  if x != x or y != y or z != z: return
  if x > 1.0e6 or x < -1.0e6: return
  if y > 1.0e6 or y < -1.0e6: return
  if z > 1.0e6 or z < -1.0e6: return
  if x == 0.0 and y == 0.0 and z == 0.0: return
  ok = true

proc distance(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx; let dy = ay - by; let dz = az - bz
  var d2 = dx*dx + dy*dy + dz*dz
  if d2 <= 0.0: return 0.0
  var d = d2
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d); inc k
  result = d

proc playersList(world: pointer): pointer =
  ## AllAlivePlayersList (List<Player>, concrete) first; RegisteredPlayers
  ## (List<IPlayer>) as a fallback.
  result = rdPtr(world, GwAllAlivePlayers)
  if result == nil:
    result = rdPtr(world, GwRegisteredPlrs)

proc dataResolved*(): bool =
  ## ESP is live only when there is a world, a validated position read, AND a
  ## way to put a pixel on the screen. Drives the ESP capability bit, so the HUD
  ## never offers a mode that cannot draw.
  gLive and gInRaid and gPosOk and espProjectable() and not dataDisabled()

# ---------------------------------------------------------------------------
# LOOT ESP -- dropped items and loose loot, its own independently gated layer
# ---------------------------------------------------------------------------
#
# The list is `EFT.GameWorld.LootList` @0x1B0, a CONCRETE `List<IKillable>`, so
# `_items`@0x10 / `_size`@0x18 are the same il2cpp ABI constants the player pass
# already uses -- no generic-instantiation offset is guessed anywhere here.
#
# THE HONEST CAVEAT, stated once and repeated in the diagnostic rather than
# buried: `LootList` is `IKillable`, which is NOT guaranteed to be homogeneous.
# Reading `LootItem` fields off an element that is a window breaker or a corpse
# would produce garbage, so every element must EARN its marker:
#
#   * `Name`@0x68 must read back as a real `System.String` (rdStr refuses a
#     declared length outside 1..1024 -- that is what a non-string pointer looks
#     like), and
#   * `_startPosition`@0x10C must be finite, non-zero and inside a sane world
#     box.
#
# An element failing either is skipped and COUNTED, and `dataDiag()` prints
# "validated N of M" -- so a systematically wrong offset shows up as a ratio,
# not as a screenful of confident markers. That is the falsifier: if this layer
# is reading the wrong thing, N is ~0 while M is large.
#
# `_startPosition` is the position the item was PLACED at, not a live transform
# read: a live read needs `Transform::get_position_Injected`, a Unity call, and
# this pass runs on the host thread where a Unity call is not legal. For static
# loose loot (the overwhelming majority) the two are the same value. For an item
# still physically rolling they differ for the second or two it is in motion.
# The setting is named `lootEspFromSpawnPos` so this is visible, not implied.

proc lootPass(s: AdminRegion; world: pointer; haveLocal: bool;
              lx, ly, lz, maxDistance: float; bbW, bbH: int;
              projecting: bool) =
  gLootSeen = 0
  gLootBoxed = 0
  gLootNamed = 0
  gLootListLen = 0
  let list = rdPtr(world, GwLootList)
  if list == nil:
    note("GameWorld+0x1B0 LootList read null")
    return
  let items = rdPtr(list, ListItemsOff)
  var n = int(rdI32(list, ListSizeOff))
  gLootListLen = n
  # Capped iteration. A raid has a few thousand loose items; 8192 is above any
  # real map and a corrupt count must never become an unbounded loop in a frame.
  if items == nil or n < 0: return
  if n > 8192: n = 8192
  var i = 0
  while i < n:
    let li = rdPtr(items, ArrDataOff + i*8)
    inc i
    if li == nil: continue
    # EARN the marker: a real string name first. This is the cheap, highly
    # selective test, so it goes first and rejects a non-LootItem before any
    # coordinate is trusted.
    let nm = rdStr(li, LiName, 20)
    if nm.len == 0: continue
    gLootNamed = gLootNamed + 1
    var x = rdF32(li, LiStartPosition + 0)
    var y = rdF32(li, LiStartPosition + 4)
    var z = rdF32(li, LiStartPosition + 8)
    if x != x or y != y or z != z: continue
    if x > 1.0e6 or x < -1.0e6: continue
    if y > 1.0e6 or y < -1.0e6: continue
    if z > 1.0e6 or z < -1.0e6: continue
    if x == 0.0 and y == 0.0 and z == 0.0: continue
    gLootSeen = gLootSeen + 1
    var dist = 0.0
    if haveLocal:
      dist = distance(x, y, z, lx, ly, lz)
      if maxDistance > 0.0 and dist > maxDistance: continue
    if not projecting: continue
    var sx = 0.0
    var sy = 0.0
    if not worldToScreen(x, y, z, bbW, bbH, sx, sy): continue
    if sx != sx or sy != sy: continue
    if sx < 0.0 or sy < 0.0 or sx > float(bbW) or sy > float(bbH): continue
    frameAdd(s, sx, sy - LootMarkerPx, sy, -1.0, -1.0, dist,
             sideLoot, flagOnScreen or flagLoot, nm)
    gLootBoxed = gLootBoxed + 1

proc collectPass(s: AdminRegion; maxDistance, lootMaxDistance: float;
                 bbW, bbH: int) =
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
    gStatus = "no GameWorld: " & gwStateText()
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # Local player, for distance + skipping self.
  var lx = 0.0; var ly = 0.0; var lz = 0.0
  var haveLocal = false
  var localPtr = 0'u64
  let me = rdPtr(world, GwMainPlayer)
  if me != nil:
    localPtr = cast[uint64](me)
    playerPos(me, haveLocal, lx, ly, lz)
    if haveLocal: gPosOk = true
  else:
    note("GameWorld+0x230 MainPlayer read null")

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
    note("player list size out of range (" & $n & ")")
    gStatus = "player list empty/out of range (" & $n & ")"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # The local player's own side, so a friendly PMC is not coloured as an enemy.
  # 0 means "could not read it", and the colouring falls back to ENEMY for every
  # PMC rather than inventing a friend.
  var localSide = 0'i32
  if me != nil:
    let lp = rdPtr(me, PlProfile)
    if lp != nil:
      let li = rdPtr(lp, PrInfo)
      if li != nil: localSide = rdI32(li, PiSide)

  frameBegin(s, bbW, bbH)
  # Snapshotted ONCE per frame, not per entity: the Unity-thread sampler can
  # flip readiness mid-loop, and half a frame of boxes is a worse artifact than
  # a whole frame of none. The LAYER toggles are snapshotted for the same
  # reason -- a layer flipping mid-loop would give half the entities one shape
  # and half another.
  let projecting = espProjectable()
  let wantNames = toggleOn(s, admEspNames)
  let wantDist  = toggleOn(s, admEspDist)
  let wantBox   = toggleOn(s, admEspBox)
  var published = 0
  var seen = 0
  var i = 0
  while i < n:
    let p = rdPtr(items, ArrDataOff + i*8)
    inc i
    if p == nil or cast[uint64](p) == localPtr: continue
    var pok = false
    var hx = 0.0; var hy = 0.0; var hz = 0.0
    playerPos(p, pok, hx, hy, hz)
    if not pok: continue
    inc seen
    gPosOk = true

    var dist = 0.0
    if haveLocal:
      dist = distance(hx, hy, hz, lx, ly, lz)
      if maxDistance > 0.0 and dist > maxDistance: continue

    var flags = 0'u32
    let isAi = rdPtr(p, PlAIData) != nil
    if isAi: flags = flags or flagIsAI
    # Side comes from the profile the client itself reads, not from "is it a
    # bot": a bot PMC is an enemy PMC and colouring it scav-yellow is a lie the
    # player acts on. An EPlayerSide outside the declared set is left UNKNOWN
    # rather than forced into one of them.
    var side = sideUnknown
    let prof = rdPtr(p, PlProfile)
    var pinfo = cast[pointer](0'u64)
    if prof != nil: pinfo = rdPtr(prof, PrInfo)
    if pinfo != nil:
      gSideOk = true
      let sv = rdI32(pinfo, PiSide)
      if sv == SideSavage: side = sideScav
      elif sv == SideUsec or sv == SideBear:
        side = (if localSide != 0'i32 and sv == localSide: sideFriend
                else: sideEnemy)
    elif isAi:
      side = sideScav          # no profile at all: the only thing still known
    # Nickname, only when the ESP: names layer is on. rdStr REFUSES anything
    # that is not a real System.String, so a blank name is a refusal, never
    # 24 bytes of plausible garbage.
    var nm = ""
    if wantNames:
      nm = rdStr(pinfo, PiNickname, 20)
      if nm.len > 0: gNameOk = true
    if nm.len == 0:
      nm = (if side == sideScav: "Scav" else: "PMC")

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
      # The presentation layers are enforced HERE, producer-side: a layer that
      # is off publishes nothing for the HUD to draw, so no overlay change was
      # needed and a layer cannot be half-honoured. "Boxes off" collapses the
      # box to a 1px caret at the head so the labels still have an anchor.
      var top = ty
      var bot = by
      if not wantBox:
        top = ty
        bot = ty + 1.0
      frameAdd(s, cx, top, bot, -1.0, -1.0,
               (if wantDist: dist else: -1.0), side, flags, nm)
      published = published + 1
  gLastCount = published
  gLastSeen = seen
  # The loot layer shares this frame and the 256-entity budget -- players are
  # added first so a loot-rich map can never crowd out a player box.
  if toggleOn(s, admLootEsp):
    lootPass(s, world, haveLocal, lx, ly, lz, lootMaxDistance, bbW, bbH,
             projecting)
  else:
    gLootSeen = 0
    gLootBoxed = 0
    gLootNamed = 0
    gLootListLen = 0
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

# ---------------------------------------------------------------------------
# THE GUARDED ENTRY POINT (host rule 3)
# ---------------------------------------------------------------------------
#
# Everything above walks live game objects. VirtualQuery makes a WRONG address
# safe; it does not make a RACE safe -- an object freed between the check and
# the read, a page decommitted by the GC mid-walk, a raid torn down while this
# frame is halfway through the player list. Those are access violations, and
# before this there was no SEH anywhere in the admin mod.
#
# So the WHOLE pass runs inside ONE `aowl_adm_seh` (`abi/aowlspt_admin.h`) --
# one guard, at the top-level entry point, never nested inside another. The
# guard refuses to re-enter itself, so if a future caller wraps this again the
# inner call runs unguarded rather than clobbering the outer `jmp_buf`, which is
# the precise failure host rule 3 exists to prevent.
#
# A fault returns NULL, counts against the self-disable budget, and leaves the
# published frame at whatever the seqlock last committed -- a stale frame of
# boxes for one tick, never a crash.

var gPassRegion: AdminRegion
var gPassMax = 0.0
var gPassLootMax = 0.0
var gPassW = 0
var gPassH = 0

proc collectThunk(a: pointer): pointer {.exportc: "aowl_adm_collect", cdecl.} =
  collectPass(gPassRegion, gPassMax, gPassLootMax, gPassW, gPassH)
  result = cast[pointer](1'u64)

# The header is `static`-only, so its definitions do NOT cross translation
# units: `adm/shared.nim` including it puts the guard in SHARED's object file,
# not this one. This TU needs its own copy of `aowl_adm_seh` -- the state that
# actually matters (the shared region) is a named file mapping, not a global, so
# two copies of the header's statics is the intended shape, not a duplication
# bug. Without this include gcc silently assumed an int-returning
# `aowl_adm_seh`, which would have thrown away the fault result.
{.emit: """#include "aowlspt_admin.h"

extern void* aowl_adm_collect(void* a);
static void* aowl_adm_collect_guarded(void* a) {
    return aowl_adm_seh((void*)aowl_adm_collect, a);
}
""".}
proc cCollectGuarded(a: pointer): pointer {.
  importc: "aowl_adm_collect_guarded", nodecl.}

proc collectAndPublish*(s: AdminRegion; maxDistance, lootMaxDistance: float;
                        bbW, bbH: int) =
  ## The per-frame pass, fault-guarded. Same signature as before, so the caller
  ## did not change; what changed is that an access violation inside it is now
  ## caught, counted and self-disabled instead of taking the client down.
  if s == nil: return
  gPassRegion = s
  gPassMax = maxDistance
  gPassLootMax = lootMaxDistance
  gPassW = bbW
  gPassH = bbH
  if cCollectGuarded(cast[pointer](0'u64)) == nil:
    gFaults = gFaults + 1
    note("access violation inside the ESP pass, trapped by the VEH guard")
    if gFaults >= MaxFaults:
      # Not a transient. Faulting every frame for the rest of the session is
      # worse than going dark, and going dark silently is worse than both --
      # dataDiag() reports SELF-DISABLED and names the first defect.
      setInRaid(s, false)

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


# ---------------------------------------------------------------------------
# MOVE SPEED -- a bounded multiplier on the two caps the client itself reads
# ---------------------------------------------------------------------------
#
# `MovementContext.<MaxSpeed>k__BackingField`@0x37C and
# `<SprintingSpeed>k__BackingField`@0x380, both MEASURED floats.
#
# The trap this avoids: multiplying the live value every frame COMPOUNDS, and a
# few seconds later the player is doing a thousand metres a second through the
# terrain. So a BASE is captured, and it is captured only while the toggle is
# OFF -- a base sampled while boosted is a boosted base, and the check that
# "the write took" would then pass forever on a runaway value. Reverting writes
# the base back, so turning the cheat off restores the game's own numbers rather
# than leaving whatever was last multiplied.

var gSpeedBase = 0.0
var gSprintBase = 0.0
var gSpeedHave = false
var gSpeedOk = false
var gSpeedMult = 1.0

proc setSpeedMultiplier*(m: float) =
  ## Clamped HERE rather than at the caller, so no route into this file can ask
  ## for a value that walks the player through a wall.
  var v = m
  if v != v: v = 1.0
  if v < 0.5: v = 0.5
  if v > 4.0: v = 4.0
  gSpeedMult = v

proc speedMultiplier*(): float = gSpeedMult
proc speedCapable*(): bool = gLive and gInRaid and gSpeedHave and not dataDisabled()

proc applySpeedImpl(on: bool) =
  let world = worldPtr()
  if world == nil: return
  let me = rdPtr(world, GwMainPlayer)
  if me == nil: return
  let mc = rdPtr(me, PlMovementContext)
  if mc == nil:
    note("Player+0x60 MovementContext read null (speed)"); return
  if not on:
    # Restore, then forget: the next raid re-captures rather than reusing a base
    # from a previous one.
    if gSpeedHave and gSpeedBase > 0.0:
      wrF32(mc, McMaxSpeed, gSpeedBase)
      wrF32(mc, McSprintSpeed, gSprintBase)
    gSpeedHave = false
    return
  if not gSpeedHave:
    let b = rdF32(mc, McMaxSpeed)
    let sb = rdF32(mc, McSprintSpeed)
    # Validate the value we are about to BASE everything on, not the write.
    if b != b or b <= 0.1 or b > 100.0: return
    if sb != sb or sb <= 0.1 or sb > 100.0: return
    gSpeedBase = b
    gSprintBase = sb
    gSpeedHave = true
  let want = gSpeedBase * gSpeedMult
  let wantS = gSprintBase * gSpeedMult
  if want <= 0.0 or want > 400.0: return
  wrF32(mc, McMaxSpeed, want)
  wrF32(mc, McSprintSpeed, wantS)
  gSpeedOk = true

# ---------------------------------------------------------------------------
# TIME FLOW -- freeze the clock, or change how fast raid time passes
# ---------------------------------------------------------------------------
#
# `EFT.GameDateTime._locked`@0x34 (bool) and `<TimeFactor>k__BackingField`@0x28
# (float), reached from `GameWorld.GameDateTime`@0xF0. All three MEASURED.
#
# This is deliberately NOT "set the time to 14:00". Doing that means writing
# `StatedGameDateTime`, a `DateTime` struct whose tick value the game then
# re-derives against `StatedRealDateTime` and `TimeFactor`; a wrong tick there
# is a plausible-looking write that silently desynchronises the raid clock, and
# nothing about it could be verified offline. Freezing and rescaling the clock
# are two writes whose FINISHED STATE is directly observable in the sky, so
# those are what ship, and the mode is labelled for what it does.

var gTimeBase = 0.0
var gTimeHave = false
var gTimeOk = false
var gTimeFactor = 1.0

proc setTimeFactor*(f: float) =
  var v = f
  if v != v: v = 1.0
  if v < 0.0: v = 0.0
  if v > 24.0: v = 24.0
  gTimeFactor = v

proc timeFactor*(): float = gTimeFactor
proc timeCapable*(): bool = gLive and gInRaid and gTimeHave and not dataDisabled()

proc applyTimeImpl(on: bool) =
  let world = worldPtr()
  if world == nil: return
  let gdt = rdPtr(world, GwGameDateTime)
  if gdt == nil:
    note("GameWorld+0xF0 GameDateTime read null"); return
  if not on:
    if gTimeHave and gTimeBase > 0.0:
      wrF32(gdt, GdtTimeFactor, gTimeBase)
      wrBool(gdt, GdtLocked, false)
    gTimeHave = false
    return
  if not gTimeHave:
    let b = rdF32(gdt, GdtTimeFactor)
    if b != b or b <= 0.0 or b > 10000.0: return
    gTimeBase = b
    gTimeHave = true
  # A factor of exactly 0 is the freeze; the game's own `_locked` flag is set
  # alongside it so a code path that recomputes the factor cannot un-freeze it.
  wrF32(gdt, GdtTimeFactor, gTimeBase * gTimeFactor)
  wrBool(gdt, GdtLocked, gTimeFactor == 0.0)
  gTimeOk = true

# ---------------------------------------------------------------------------
# THE GUARDED WRITE PASS -- stamina + speed + time, ONE guard, never nested
# ---------------------------------------------------------------------------

proc writesThunk(a: pointer): pointer {.exportc: "aowl_adm_writes", cdecl.} =
  let s = gPassRegion
  if toggleOn(s, admStamina): applyStaminaImpl()
  applySpeedImpl(toggleOn(s, admSpeed))
  applyTimeImpl(toggleOn(s, admTimeOfDay))
  result = cast[pointer](1'u64)

{.emit: """
extern void* aowl_adm_writes(void* a);
static void* aowl_adm_writes_guarded(void* a) {
    return aowl_adm_seh((void*)aowl_adm_writes, a);
}
""".}
proc cWritesGuarded(a: pointer): pointer {.
  importc: "aowl_adm_writes_guarded", nodecl.}

proc applyWrites*(s: AdminRegion) =
  ## Every game-memory WRITE this mod makes, in one fault-guarded body. Called
  ## only in a raid; each individual write is separately toggle-gated inside, so
  ## with every toggle off this walks three nil checks and writes nothing.
  if s == nil or not gLive or not dataReady() or dataDisabled(): return
  gPassRegion = s
  if cWritesGuarded(cast[pointer](0'u64)) == nil:
    gFaults = gFaults + 1
    note("access violation inside the cheat write pass, trapped by the guard")

proc revertWrites*() =
  ## Put the game's own numbers back. Called when a raid ends and on unload, so
  ## a boosted speed or a frozen clock cannot survive into the next raid.
  if not gLive: return
  applySpeedImpl(false)
  applyTimeImpl(false)

proc applyStaminaImpl() =
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
  r.add "  positions    : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gPosOk: "PASS  Player+0x60->MovementContext+0x370 validated (" &
                      $gLastSeen & " players)"
         else: "FAIL  no player position passed the finite/bounded check") & "\n"
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
  r.add "  god mode     : " &
        (if not godCapable(): "FAIL  GameAssembly.dll not present"
         elif godmodeIsOn(): "PASS  patch installed at 0x731480"
         elif not gInRaid: "INCONCLUSIVE  deferred to in-raid; not patched outside one"
         else: "INCONCLUSIVE  in raid but toggle off") & "\n"
  r.add "  stamina      : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gStamOk: "PASS  PhysicalBase+0x8C -> Stamina+0x10 written"
         else: "INCONCLUSIVE  not attempted or capacity implausible") & "\n"
  r.add "  esp identity : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gNameOk: "PASS  nicknames read (Player+0x9C0->ProfileInfo+0x10)" &
                       (if gSideOk: " and sides (+0x48)" else: "")
         elif gSideOk: "INCONCLUSIVE  sides read, but NO nickname string " &
                       "validated -- boxes are labelled PMC/Scav"
         else: "INCONCLUSIVE  no profile reached; boxes fall back to PMC/Scav") & "\n"
  r.add "  loot esp     : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to read"
         elif gLootListLen == 0: "INCONCLUSIVE  GameWorld+0x1B0 LootList is " &
                                 "empty or unreadable -- no loot to look at"
         elif gLootSeen == 0: "FAIL  " & $gLootListLen & " entries in LootList " &
                              "but 0 validated as LootItem-shaped (" &
                              $gLootNamed & " had a readable name) -- the " &
                              "list is not the LootItems it was taken to be, " &
                              "or 0x68/0x10C moved on this build"
         elif not camReady(): "INCONCLUSIVE  " & $gLootSeen & " of " &
                              $gLootListLen & " validated, but there is no " &
                              "projection to draw them with"
         elif gLootBoxed > 0: "PASS  " & $gLootBoxed & " markers of " &
                              $gLootSeen & " validated (" & $gLootListLen &
                              " in the list)"
         else: "INCONCLUSIVE  " & $gLootSeen & " validated, 0 on screen -- " &
               "all behind you or out of range") & "\n"
  r.add "  move speed   : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to write"
         elif gSpeedOk: "PASS  MovementContext+0x37C/+0x380 set to base x" &
                        $gSpeedMult
         elif gSpeedHave: "INCONCLUSIVE  base captured, multiplier not applied yet"
         else: "INCONCLUSIVE  toggle off, or the base speed read implausible") & "\n"
  r.add "  time flow    : " &
        (if not gInRaid: "INCONCLUSIVE  no raid, nothing to write"
         elif gTimeOk: "PASS  GameDateTime+0x28 TimeFactor = base x" & $gTimeFactor &
                       (if gTimeFactor == 0.0: " (frozen, +0x34 _locked set)" else: "")
         else: "INCONCLUSIVE  toggle off, or TimeFactor read implausible") & "\n"
  r.add "  faults       : " & $gFaults & " of " & $MaxFaults &
        (if dataDisabled(): "  SELF-DISABLED" else: "") & "\n"
  r.add "  first defect : " & dataDefectText()
  result = r
