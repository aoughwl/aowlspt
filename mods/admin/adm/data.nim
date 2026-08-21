## The ESP data pass -- pure field-offset memory reads, no managed method calls.
##
## On build 1.1.0.1.46777 the per-frame managed method pointers are stripped by
## the anti-cheat, so nothing here calls a game method. It reads the object graph
## the way `fov`/`sain` reach fields and the way every internal cheat reads a
## world: resolve a field's offset once with `il2cpp_field_get_offset` (a
## metadata query, not a stripped method), then read `*(T*)(object + offset)`.
## That works from any thread, so this whole pass runs on the host's `on_update`
## -- the dead Unity-thread bridge is not on the path at all.
##
## What it reads: the GameWorld singleton (a static field), its player list, and
## per player the position, side and AI flag; plus the camera's view-projection
## matrix. It projects each player to screen and publishes the boxes into the
## shared region the native HUD draws from.
##
## ---------------------------------------------------------------------------
## THE LIVE-ITERATION PARAMETERS
## ---------------------------------------------------------------------------
##
## Everything below resolves offsets **by name** through reflection, so the
## parameters that need confirming on this exact build are field/class *names*,
## not raw numbers -- reflection turns a correct name into the right offset for
## the build. They are the pre-1.0 surface and have never been checked against
## BSG's post-1.0 client. A wrong name is a refused resolution and a mode that
## reads "unavailable" -- never a wrong read or a crash. The one thing that is
## not a name is the il2cpp `List<T>`/array memory layout, which is an ABI
## constant and stable across builds.
##
## Until the confirmed names (or the metadata dump the deep-probe is producing)
## land here, `dataResolved()` is false, `inRaid` may still be set if the
## singleton alone resolves, and the HUD draws the menu but no boxes. That is the
## documented safe-by-default state.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast
import shared

# il2cpp x64 memory layout -- ABI constants, not build-specific.
const
  ListItemsOff = 0x10   ## List<T>._items  (the T[] backing array)
  ListSizeOff  = 0x18   ## List<T>._size   (int)
  ArrDataOff   = 0x20   ## first element of an il2cpp array on x64

# ---- names to confirm on build 1.1.0.1.46777 (see header) ----
const
  # The GameWorld singleton, as (class, static-field). EFT holds it in
  # Comfort.Common.Singleton<GameWorld>; the dump names the resolvable form.
  SingletonClass = "EFT.GameWorld"
  SingletonField = "Instance"
  # GameWorld -> the player list.
  PlayersField   = "RegisteredPlayers"
  # Player fields.
  PosField       = "Position"
  SideField      = "Side"
  IsAiField      = "IsAI"
  HealthField    = ""          ## empty: no confirmed numeric-health field yet
  # The camera + its view-projection matrix.
  CameraClass    = "EFT.CameraControl.CameraManager"
  CameraField    = "Instance"
  VpMatrixField  = ""          ## empty: the VP-matrix source is not confirmed

var gRt: Il2Cpp
var gLive = false
var gStatus = "not attempted"
var gResolvedWorld = false
var gLastCount = 0
var gInRaid = false

proc dataOpen*(): bool =
  ## Bind the already-loaded GameAssembly.dll. Cheap once it succeeds.
  if gLive:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    gStatus = "GameAssembly not up yet"
    return false
  gLive = true
  result = true

proc offOf(cls: Il2CppClass; name: string): int =
  ## The byte offset of an instance field, searched up the base chain, or -1.
  result = -1
  if cls == nil or name.len == 0:
    return
  var c = cls
  while c != nil:
    let f = findField(gRt, c, name)
    if f != nil:
      return fieldOffset(gRt, f)
    c = classParent(gRt, c)

proc staticPtr(className, fieldName: string): Il2CppPtr =
  ## Read a static reference field WITHOUT running its class ctor (which would
  ## fault off Unity's thread). `staticFieldData` + offset + a guarded read.
  result = nullPtr()
  let cls = findClass(gRt, className)
  if cls == nil:
    return
  let f = findField(gRt, cls, fieldName)
  if f == nil:
    return
  let sdata = staticFieldData(gRt, cls)
  if sdata == nil:
    return
  let off = fieldOffset(gRt, f)
  result = cast[Il2CppPtr](rdPtr(cast[pointer](sdata), off))

proc gameWorld(): Il2CppPtr =
  ## The live GameWorld, or nil when not in a raid.
  result = staticPtr(SingletonClass, SingletonField)

# Cached offsets, resolved once against the first player's own class.
var gPosOff = -2      ## -2 = not tried, -1 = tried and absent
var gSideOff = -2
var gAiOff = -2
var gHpOff = -2
var gPlayersOff = -2

proc distance(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx; let dy = ay - by; let dz = az - bz
  var d2 = dx*dx + dy*dy + dz*dz
  if d2 <= 0.0: return 0.0
  var d = d2
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d)
    inc k
  result = d

proc readVpMatrix(m: var array[16, float32]): bool =
  ## The camera view-projection matrix, by field offset. Unresolved until the
  ## field is confirmed (VpMatrixField empty) -> no projection this build.
  if VpMatrixField.len == 0:
    return false
  let cam = staticPtr(CameraClass, CameraField)
  if cam == nil:
    return false
  let camCls = objectClass(gRt, cam)
  let off = offOf(camCls, VpMatrixField)
  if off < 0:
    return false
  for i in 0 ..< 16:
    m[i] = float32(rdF32(cast[pointer](cam), off + i*4))
  result = true

proc dataResolved*(): bool =
  ## Whether the full ESP chain resolved: a world, a players field, position,
  ## and a projection matrix. Drives the ESP capability bit.
  gResolvedWorld and gPlayersOff >= 0 and gPosOff >= 0 and VpMatrixField.len > 0

proc dataInRaid*(): bool = gInRaid
proc dataStatus*(): string = gStatus
proc dataRuntime*(): Il2Cpp = gRt
proc dataLive*(): bool = gLive

proc zero16(): array[16, float32] =
  result = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]

proc collectAndPublish*(s: AdminRegion; maxDistance: float; bbW, bbH: int) =
  ## One pass: read the world, project, publish. Never writes to the game.
  if not gLive:
    setInRaid(s, false)
    return
  let world = gameWorld()
  gResolvedWorld = (world != nil)
  gInRaid = (world != nil)
  setInRaid(s, gInRaid)
  if world == nil:
    gStatus = "no GameWorld (not in a raid), or the singleton field name needs confirming"
    frameBegin(s, bbW, bbH)
    frameCommit(s)
    return

  # The players list field on the world.
  if gPlayersOff == -2:
    gPlayersOff = offOf(objectClass(gRt, world), PlayersField)
  if gPlayersOff < 0:
    gStatus = "GameWorld resolved, but the players-list field '" & PlayersField &
              "' did not -- confirm the name"
    frameBegin(s, bbW, bbH); frameCommit(s)
    return

  let list = cast[Il2CppPtr](rdPtr(cast[pointer](world), gPlayersOff))
  if list == nil:
    gStatus = "players list is null this frame"
    frameBegin(s, bbW, bbH); frameCommit(s)
    return
  let items = rdPtr(cast[pointer](list), ListItemsOff)
  var n = int(rdI32(cast[pointer](list), ListSizeOff))
  if items == nil or n <= 0 or n > 1024:
    gStatus = "players list empty or out of range (" & $n & ")"
    frameBegin(s, bbW, bbH); frameCommit(s)
    return

  var vp = zero16()
  let haveVp = readVpMatrix(vp)

  frameBegin(s, bbW, bbH)
  var published = 0
  var i = 0
  while i < n:
    let p = cast[Il2CppPtr](rdPtr(items, ArrDataOff + i*8))
    inc i
    if p == nil:
      continue
    # Resolve the per-player offsets once, against the first real player's class.
    if gPosOff == -2:
      let pc = objectClass(gRt, p)
      gPosOff = offOf(pc, PosField)
      gSideOff = offOf(pc, SideField)
      gAiOff = offOf(pc, IsAiField)
      gHpOff = (if HealthField.len > 0: offOf(pc, HealthField) else: -1)
    if gPosOff < 0:
      continue
    let wx = rdF32(cast[pointer](p), gPosOff + 0)
    let wy = rdF32(cast[pointer](p), gPosOff + 4)
    let wz = rdF32(cast[pointer](p), gPosOff + 8)

    var side = sideUnknown
    if gSideOff >= 0:
      side = int32(rdI32(cast[pointer](p), gSideOff))
    var flags = 0'u32
    if gAiOff >= 0 and rdI32(cast[pointer](p), gAiOff) != 0'i32:
      flags = flags or flagIsAI
    var hp = -1.0
    if gHpOff >= 0:
      hp = rdF32(cast[pointer](p), gHpOff)

    var cx = 0.0; var cyTop = 0.0; var cyBot = 0.0
    var onScreen = false
    if haveVp:
      var fx = 0.0; var fy = 0.0
      var hx = 0.0; var hy = 0.0
      let okF = project(vp, wx, wy, wz, bbW, bbH, fx, fy)
      let okH = project(vp, wx, wy + 1.8, wz, bbW, bbH, hx, hy)
      if okF and okH:
        cx = (fx + hx) * 0.5
        cyTop = hy
        cyBot = fy
        flags = flags or flagOnScreen
        onScreen = true
    if onScreen:
      frameAdd(s, cx, cyTop, cyBot, hp, (if hp >= 0.0: 100.0 else: -1.0),
               0.0, side, flags, "")
      inc published
  gLastCount = published
  frameCommit(s)
  if haveVp:
    gStatus = "in raid; published " & $published & " of " & $n & " players"
  else:
    gStatus = "in raid; positions read but no view-projection matrix -- " &
              "confirm VpMatrixField to project (no boxes until then)"

# ---------------------------------------------------------------------------
# Cheats -- memory writes, no managed calls. Frameworks, capability-gated: each
# is "available" only when its write target is confirmed, so nothing turns on a
# mode that would silently do nothing (or write a wrong field).
# ---------------------------------------------------------------------------

const
  MainPlayerField = "MainPlayer"
  # Write targets to confirm on this build (empty => the mode is "unavailable").
  GodHealthField  = ""   ## a float to pin to full each frame (godmode)
  StaminaField    = ""   ## stamina.Current to pin each frame

var gMainOff = -2

proc mainPlayer(): Il2CppPtr =
  let w = gameWorld()
  if w == nil: return nullPtr()
  if gMainOff == -2:
    gMainOff = offOf(objectClass(gRt, w), MainPlayerField)
  if gMainOff < 0: return nullPtr()
  result = cast[Il2CppPtr](rdPtr(cast[pointer](w), gMainOff))

proc godCapable*(): bool = gLive and GodHealthField.len > 0
proc staminaCapable*(): bool = gLive and StaminaField.len > 0

proc applyGodmode*() =
  ## Pin the local player's health to full each frame. Memory write, no managed
  ## call. Inert until GodHealthField is confirmed.
  if GodHealthField.len == 0: return
  let p = mainPlayer()
  if p == nil: return
  let off = offOf(objectClass(gRt, p), GodHealthField)
  if off >= 0:
    wrF32(cast[pointer](p), off, 100.0)

proc applyStamina*() =
  ## Pin stamina to full each frame. Inert until StaminaField (and its chain) is
  ## confirmed.
  if StaminaField.len == 0: return
  let p = mainPlayer()
  if p == nil: return
  discard p
