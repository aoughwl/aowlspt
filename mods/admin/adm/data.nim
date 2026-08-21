## The ESP data pass + cheats -- pure field-offset memory reads/writes and a
## static byte-patch. No managed method calls (their pointers are stripped on
## build 1.1.0.1.46777), no Unity thread.
##
## ---------------------------------------------------------------------------
## HOW THE NAMES BELOW WERE VERIFIED
## ---------------------------------------------------------------------------
##
## Every field/type/RVA below was read out of the DECRYPTED global-metadata for
## this exact build with `tools/il2cpp_resolve.py` (the resolver that reproduces
## the BE-bypass RVAs byte-for-byte) plus a field dumper over the same metadata
## (Il2CppTypeDefinition.fieldStart@32/field_count@68, fields table = metadata
## property 11, Il2CppFieldDefinition{nameIndex@0} 12 bytes). So these are the
## real member names of build 46777, not the pre-1.0 guesses this file used to
## carry. Offsets are still resolved BY NAME at runtime (reflection turns the
## verified name into the build's offset), so a metadata/runtime mismatch is a
## refused resolution and a degrade, never a wrong read.
##
## Confirmed from the dump:
##   EFT.GameWorld           : RegisteredPlayers, AllAlivePlayersList (List<>),
##                             MainPlayer   -- all instance fields
##   EFT.Player              : <CameraPosition>k__BackingField (Vector3, the eye
##                             position), Physical, _healthController,
##                             <Profile>k__BackingField, <AIData>k__BackingField
##   Stamina                 : Current, TotalCapacity (floats)
##   EFT.CameraControl.CameraManager : static `instance`, <Camera>k__BackingField,
##                             _fov
##   EFT.Player::ApplyDamageInfo  RVA 0x731480  (prologue 48 89 5C 24 20 ...)
##   EFT.Player::ReceiveDamage    RVA 0x6F8D10
##
## ---------------------------------------------------------------------------
## THE TWO REMAINING RUNTIME-RESOLUTION GATES (documented, degrade-safe)
## ---------------------------------------------------------------------------
##
##  1. **The GameWorld singleton.** It lives in `Comfort.Common.Singleton<
##     GameWorld>._instance` -- a static field on a *generic instantiation*,
##     which il2cpp reflection cannot name through `findClass`. Acquiring it
##     needs the generics API (or the bridge's Unity-thread reflection, which the
##     team confirmed can resolve fields by name on that thread). Until then
##     `worldSingleton()` returns nil, `inRaid` is false, and there is no player
##     list -- ESP shows nothing, but God mode (a static code patch) still works.
##
##  2. **The camera view-projection matrix.** `UnityEngine.Camera` computes
##     worldToCameraMatrix/projectionMatrix natively -- there is no managed
##     backing field. The matrix is read from the native camera object (managed
##     Camera + 0x10 -> native ptr, then + `VpNativeOff`). `VpNativeOff` is the
##     one UnityPlayer-side offset not in il2cpp metadata; it is validated at
##     runtime (a sane projection matrix, finite, bounded) so a wrong value is
##     rejected rather than drawn as garbage. Set it once from a UnityPlayer dump
##     or an in-raid scan.
##
## Everything else -- the player walk, positions, God mode, stamina -- is real
## and build-correct.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import shared

# il2cpp x64 memory layout -- ABI constants, stable across builds.
const
  ListItemsOff  = 0x10   ## List<T>._items (the T[] backing array)
  ListSizeOff   = 0x18   ## List<T>._size (int)
  ArrDataOff    = 0x20   ## first element of an il2cpp array on x64
  UnityNativeOff = 0x10  ## UnityEngine.Object.m_CachedPtr (native object)

# ---- verified names for build 1.1.0.1.46777 (see header) ----
const
  SingletonClass  = "EFT.GameWorld"
  SingletonField  = "Instance"           ## best-effort; the real one is generic
  PlayersFieldA   = "RegisteredPlayers"
  PlayersFieldB   = "AllAlivePlayersList"
  MainPlayerField = "MainPlayer"
  # Player fields.
  PosField        = "<CameraPosition>k__BackingField"   ## Vector3 (eye position)
  AiDataField     = "<AIData>k__BackingField"           ## non-null => AI
  PhysicalField   = "Physical"
  # Camera.
  CameraMgrClass  = "EFT.CameraControl.CameraManager"
  CameraMgrInst   = "instance"                          ## static field
  CameraField     = "<Camera>k__BackingField"
  # Stamina.
  StaminaField    = "Stamina"          ## on Physical
  StaminaCurrent  = "Current"          ## on Stamina
  StaminaMax      = "TotalCapacity"

# God mode: the damage applier's native RVA (resolved offline). ApplyDamageInfo
# is the whole-player entry; patching it to `xor eax,eax; ret` neuters damage.
const GodDamageRva* = 0x731480'u32

# The one UnityPlayer-side offset not in il2cpp metadata. 0 = disabled (no
# projection, so no boxes) until confirmed -- deliberately not a guess that would
# draw garbage. Set from a UnityPlayer dump / in-raid scan.
const VpNativeOff = 0

var gRt: Il2Cpp
var gLive = false
var gStatus = "not attempted"
var gInRaid = false
var gLastCount = 0

proc dataOpen*(): bool =
  if gLive: return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    gStatus = "GameAssembly not up yet"
    return false
  gLive = true
  result = true

proc dataInRaid*(): bool = gInRaid
proc dataStatus*(): string = gStatus
proc dataLive*(): bool = gLive

proc offOf(cls: Il2CppClass; name: string): int =
  ## Instance-field byte offset, searched up the base chain, or -1.
  result = -1
  if cls == nil or name.len == 0: return
  var c = cls
  while c != nil:
    let f = findField(gRt, c, name)
    if f != nil:
      return fieldOffset(gRt, f)
    c = classParent(gRt, c)

proc staticPtr(className, fieldName: string): Il2CppPtr =
  ## Read a static reference field without running a class ctor: static data
  ## block + field offset + a guarded pointer read.
  result = nullPtr()
  let cls = findClass(gRt, className)
  if cls == nil: return
  let f = findField(gRt, cls, fieldName)
  if f == nil: return
  let sdata = staticFieldData(gRt, cls)
  if sdata == nil: return
  result = cast[Il2CppPtr](rdPtr(cast[pointer](sdata), fieldOffset(gRt, f)))

proc worldSingleton(): Il2CppPtr =
  ## GATE 1 (see header): the GameWorld singleton. The real store is a generic
  ## static this cannot name; the best-effort non-generic lookup below returns
  ## nil on this build, so ESP stays dark while God mode still works.
  result = staticPtr(SingletonClass, SingletonField)

# ---- camera view-projection ----

var gCamMgrInstOff = -2
var gCamFieldOff = -2

proc zero16(): array[16, float32] =
  result = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]

proc sane(m: array[16, float32]): bool =
  ## A projection matrix is finite and bounded; garbage memory is not. Rejects a
  ## wrong VpNativeOff instead of drawing nonsense.
  var nonZero = false
  for v in m:
    if v != v: return false                 # NaN
    if v > 1.0e9 or v < -1.0e9: return false # inf-ish / garbage
    if v != 0.0: nonZero = true
  result = nonZero

proc cameraVp(m: var array[16, float32]): bool =
  ## GATE 2 (see header): the world->clip matrix from the native camera.
  if VpNativeOff == 0:
    return false
  let mgr = staticPtr(CameraMgrClass, CameraMgrInst)
  if mgr == nil: return false
  if gCamFieldOff == -2:
    gCamFieldOff = offOf(objectClass(gRt, mgr), CameraField)
  if gCamFieldOff < 0: return false
  let cam = rdPtr(cast[pointer](mgr), gCamFieldOff)      # managed UnityEngine.Camera
  if cam == nil: return false
  let native = rdPtr(cam, UnityNativeOff)                # native camera object
  if native == nil: return false
  for i in 0 ..< 16:
    m[i] = float32(rdF32(native, VpNativeOff + i*4))
  result = sane(m)

# ---- the walk ----

var gPlayersOff = -2
var gMainOff = -2
var gPosOff = -2
var gAiOff = -2

proc dataResolved*(): bool =
  ## ESP is fully live only with a world, a player list, positions, and a VP
  ## matrix. Drives the ESP capability bit.
  gLive and gInRaid and gPlayersOff >= 0 and gPosOff >= 0 and VpNativeOff != 0

proc distance(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx; let dy = ay - by; let dz = az - bz
  var d2 = dx*dx + dy*dy + dz*dz
  if d2 <= 0.0: return 0.0
  var d = d2
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d); inc k
  result = d

proc playersList(world: Il2CppPtr): Il2CppPtr =
  if gPlayersOff == -2:
    gPlayersOff = offOf(objectClass(gRt, world), PlayersFieldA)
    if gPlayersOff < 0:
      gPlayersOff = offOf(objectClass(gRt, world), PlayersFieldB)
  if gPlayersOff < 0: return nullPtr()
  result = cast[Il2CppPtr](rdPtr(cast[pointer](world), gPlayersOff))

proc collectAndPublish*(s: AdminRegion; maxDistance: float; bbW, bbH: int) =
  if not gLive:
    setInRaid(s, false); return
  let world = worldSingleton()
  gInRaid = (world != nil)
  setInRaid(s, gInRaid)
  if world == nil:
    gStatus = "no GameWorld -- singleton is a generic static (GATE 1); God mode " &
              "still works, ESP is dark until it is acquired"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  # Local player, for distance + skipping self.
  var lx = 0.0; var ly = 0.0; var lz = 0.0
  var haveLocal = false
  var localPtr = 0'u64
  if gMainOff == -2:
    gMainOff = offOf(objectClass(gRt, world), MainPlayerField)
  if gMainOff >= 0:
    let me = cast[Il2CppPtr](rdPtr(cast[pointer](world), gMainOff))
    if me != nil:
      localPtr = cast[uint64](me)
      if gPosOff == -2: gPosOff = offOf(objectClass(gRt, me), PosField)
      if gPosOff >= 0:
        lx = rdF32(cast[pointer](me), gPosOff + 0)
        ly = rdF32(cast[pointer](me), gPosOff + 4)
        lz = rdF32(cast[pointer](me), gPosOff + 8)
        haveLocal = true

  let list = playersList(world)
  if list == nil:
    gStatus = "GameWorld found but the player list field did not resolve"
    frameBegin(s, bbW, bbH); frameCommit(s); return
  let items = rdPtr(cast[pointer](list), ListItemsOff)
  var n = int(rdI32(cast[pointer](list), ListSizeOff))
  if items == nil or n <= 0 or n > 1024:
    gStatus = "player list empty/out of range (" & $n & ")"
    frameBegin(s, bbW, bbH); frameCommit(s); return

  var vp = zero16()
  let haveVp = cameraVp(vp)

  frameBegin(s, bbW, bbH)
  var published = 0
  var i = 0
  while i < n:
    let p = cast[Il2CppPtr](rdPtr(items, ArrDataOff + i*8))
    inc i
    if p == nil or cast[uint64](p) == localPtr: continue
    if gPosOff == -2: gPosOff = offOf(objectClass(gRt, p), PosField)
    if gPosOff < 0: continue
    let hx = rdF32(cast[pointer](p), gPosOff + 0)   # head/eye position
    let hy = rdF32(cast[pointer](p), gPosOff + 4)
    let hz = rdF32(cast[pointer](p), gPosOff + 8)

    var dist = 0.0
    if haveLocal:
      dist = distance(hx, hy, hz, lx, ly, lz)
      if maxDistance > 0.0 and dist > maxDistance: continue

    if gAiOff == -2: gAiOff = offOf(objectClass(gRt, p), AiDataField)
    var flags = 0'u32
    var side = sideEnemy
    if gAiOff >= 0 and rdPtr(cast[pointer](p), gAiOff) != nil:
      flags = flags or flagIsAI
      side = sideScav

    if haveVp:
      # The eye is the head; feet are ~1.7 m below it.
      var sxH = 0.0; var syH = 0.0
      var sxF = 0.0; var syF = 0.0
      let okH = project(vp, hx, hy, hz, bbW, bbH, sxH, syH)
      let okF = project(vp, hx, hy - 1.7, hz, bbW, bbH, sxF, syF)
      if okH and okF:
        frameAdd(s, (sxH + sxF) * 0.5, syH, syF, -1.0, -1.0, dist,
                 side, flags or flagOnScreen, "")
        inc published
  gLastCount = published
  frameCommit(s)
  if haveVp:
    gStatus = "in raid; boxed " & $published & " of " & $n & " players"
  else:
    gStatus = "in raid; " & $n & " players read, but no VP matrix (GATE 2: set " &
              "VpNativeOff) -- positions collected, no boxes yet"

# ---------------------------------------------------------------------------
# God mode -- the static byte-patch. Works from any thread, needs no world.
# ---------------------------------------------------------------------------

proc godCapable*(): bool = gameAssemblyPresent()

proc setGodmode*(on: bool) =
  ## Apply/revert the ApplyDamageInfo byte-patch. Idempotent.
  if not gameAssemblyPresent(): return
  discard godmodePatch(on, GodDamageRva)

proc godStatus*(): string =
  if godmodeIsOn(): "god=ON (ApplyDamageInfo patched, global)"
  else: "god=off"

# ---------------------------------------------------------------------------
# Infinite stamina -- Physical.Stamina.Current write. Needs a world+player.
# ---------------------------------------------------------------------------

var gPhysOff = -2
var gStamOff = -2
var gStamCurOff = -2
var gStamMaxOff = -2

proc staminaCapable*(): bool =
  gLive and gInRaid and gPhysOff >= 0 and gStamOff >= 0 and gStamCurOff >= 0

proc applyStamina*() =
  if not gLive: return
  let world = worldSingleton()
  if world == nil: return
  if gMainOff < 0: return
  let me = cast[Il2CppPtr](rdPtr(cast[pointer](world), gMainOff))
  if me == nil: return
  if gPhysOff == -2: gPhysOff = offOf(objectClass(gRt, me), PhysicalField)
  if gPhysOff < 0: return
  let phys = cast[Il2CppPtr](rdPtr(cast[pointer](me), gPhysOff))
  if phys == nil: return
  if gStamOff == -2: gStamOff = offOf(objectClass(gRt, phys), StaminaField)
  if gStamOff < 0: return
  let stam = cast[Il2CppPtr](rdPtr(cast[pointer](phys), gStamOff))
  if stam == nil: return
  if gStamCurOff == -2:
    gStamCurOff = offOf(objectClass(gRt, stam), StaminaCurrent)
    gStamMaxOff = offOf(objectClass(gRt, stam), StaminaMax)
  if gStamCurOff < 0: return
  var maxVal = 100.0
  if gStamMaxOff >= 0:
    let m = rdF32(cast[pointer](stam), gStamMaxOff)
    if m > 0.0: maxVal = m
  wrF32(cast[pointer](stam), gStamCurOff, maxVal)
