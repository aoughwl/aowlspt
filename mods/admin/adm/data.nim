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
    var side = sideEnemy
    if rdPtr(p, PlAIData) != nil:
      flags = flags or flagIsAI
      side = sideScav

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
      frameAdd(s, cx, ty, by, -1.0, -1.0, dist, side, flags,
               (if (flags and flagIsAI) != 0'u32: "Scav" else: "PMC"))
      published = published + 1
  gLastCount = published
  gLastSeen = seen
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
  r.add "  faults       : " & $gFaults & " of " & $MaxFaults &
        (if dataDisabled(): "  SELF-DISABLED" else: "") & "\n"
  r.add "  first defect : " & dataDefectText()
  result = r
