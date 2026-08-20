## The ESP data pass: walk the world on Unity's thread, read every player's
## position and side, read the camera's view-projection matrix, and project each
## player to the screen. Nothing here draws -- it produces the geometry the
## renderer paints.
##
## Everything is bound **against the object it is reached on** (`bindOnObject`),
## because a bound call is non-virtual and this chain is nothing but subclasses
## and generics: SPT's raid world is a `GameWorld` subclass, the alive-player
## list is a `List<IPlayer>` `findClass` cannot name, and bots and the local
## player are different `Player` subclasses. The `Vector3`/`Matrix4x4` getters
## return value types larger than a register, so they are read by their native
## hidden-return-pointer shape (`bindRaw`), exactly as `mods/morebots` reads a
## bot's position. A refused binding is a `why` line and an empty snapshot, never
## a wrong number.
##
## Names below are the pre-1.0 surface and have never been checked against BSG's
## post-1.0 client. `worldDiag()` prints every binding's own account.

import std/strutils
import aowlspt
import aowlspt/il2cpp
import aowlspt/fast

# ---------------------------------------------------------------------------
# The snapshot the renderer reads
# ---------------------------------------------------------------------------

type
  EspEntity* = object
    cx*, top*, bottom*: float   ## screen box: centre, head, feet (pixels)
    distance*: float            ## metres from the local player
    side*: int                  ## raw EPlayerSide, or -1
    isAI*: bool
    onScreen*: bool

var gEnts: seq[EspEntity] = @[]
var gScreenW = 1920
var gScreenH = 1080
var gLocalPtr = 0'u64

proc espEntities*(): seq[EspEntity] = gEnts
proc espScreenW*(): int = gScreenW
proc espScreenH*(): int = gScreenH
proc localPlayerPtr*(): uint64 = gLocalPtr

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------

var gRt: Il2Cpp
var gLive = false

proc worldRuntime*(): Il2Cpp = gRt
proc worldReady*(): bool = gLive

proc openWorld*(): bool =
  ## Binds the already-loaded GameAssembly.dll. Cheap once it has succeeded,
  ## retried while it has not.
  if gLive:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  gLive = true
  result = true

# ---------------------------------------------------------------------------
# ObjBind -- bind against the object's own class, at most once per class.
# The exact discipline from mods/morebots/bots/census.nim.
# ---------------------------------------------------------------------------

type
  ObjBind = object
    b: Binding
    cls: Il2CppClass
    tried: bool
    why: string

proc noObjBind(): ObjBind =
  ObjBind(b: Binding(ok: false, why: "", target: "", fn: nullPtr(),
                     info: nullPtr(), argc: 0'i32, slots: 0'i32, mask: 0'u32,
                     ret: fkNone, isStatic: false, bindNs: 0'i64),
          cls: cast[Il2CppClass](0), tried: false, why: "not attempted")

proc changedClass(o: var ObjBind; obj: Il2CppPtr): bool =
  let c = objectClass(gRt, obj)
  if c == nil:
    return false
  if o.tried and o.cls == c:
    return false
  o.cls = c
  result = true

proc ensureCall(o: var ObjBind; obj: Il2CppPtr; member: string;
                kinds: openArray[FastKind]; ret: FastKind): bool =
  if obj == nil or not gLive:
    return false
  if changedClass(o, obj):
    o.tried = true
    o.b = bindOnObject(gRt, obj, member, kinds, ret)
    o.why = o.b.why
  result = o.b.ok

proc noKinds(): seq[FastKind] =
  result = @[]

# ---------------------------------------------------------------------------
# A value-type getter read by its native hidden-return-pointer shape.
# Vector3 (12 bytes) and Matrix4x4 (64 bytes) both come back this way.
# ---------------------------------------------------------------------------

proc bindShapedGetter(o: var ObjBind; obj: Il2CppPtr; member: string): bool =
  ## Binds `member` (a zero-arg getter returning a value type larger than a
  ## register) against the object's class, as `void* get(void* sret, void* this,
  ## MethodInfo*)` -- two pointer slots, no float slot, mask 0.
  if obj == nil or not gLive:
    return false
  if not changedClass(o, obj):
    return o.b.ok
  o.tried = true
  var cls = objectClass(gRt, obj)
  var declaring: Il2CppClass = cast[Il2CppClass](0)
  var c = cls
  while c != nil:
    let m = findMethod(gRt, c, member, 0)
    if m != nil:
      declaring = c
      break
    c = classParent(gRt, c)
  if declaring == nil:
    o.b.ok = false
    o.why = "no " & member & " on " & fullName(gRt, cls) & " or a base class"
    return false
  o.b = bindRaw(gRt, declaring, fullName(gRt, declaring), member,
                0, 2, 0'u32, fkPtr)
  o.why = o.b.why
  result = o.b.ok

proc readVec3(o: var ObjBind; obj: Il2CppPtr; x, y, z: var float): bool =
  ## One shaped call into a 4-float buffer (three used; the fourth is slack so a
  ## 16-byte value type cannot overrun). The return value is the buffer address.
  x = 0.0; y = 0.0; z = 0.0
  if not bindShapedGetter(o, obj, "get_Position"):
    return false
  var buf: array[4, float32] = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  var s = shaped()
  addSlotPtr(s, cast[Il2CppPtr](addr buf[0]))
  addSlotPtr(s, obj)
  discard callShapedPtr(o.b, s)
  x = float(buf[0]); y = float(buf[1]); z = float(buf[2])
  result = true

proc zero16(): array[16, float32] =
  ## nimony cannot prove a loop-filled array initialised, so the zero matrix is a
  ## literal. Sixteen zeros, once.
  result = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32,
            0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]

proc readMat16(o: var ObjBind; obj: Il2CppPtr; member: string;
               outM: var array[16, float32]): bool =
  ## A Matrix4x4 getter into sixteen floats, Unity column-major.
  if not bindShapedGetter(o, obj, member):
    return false
  var buf = zero16()
  var s = shaped()
  addSlotPtr(s, cast[Il2CppPtr](addr buf[0]))
  addSlotPtr(s, obj)
  discard callShapedPtr(o.b, s)
  for i in 0 ..< 16: outM[i] = buf[i]
  result = true

# ---------------------------------------------------------------------------
# Projection -- Unity column-major, deterministic. clip = M*(x,y,z,1).
# ---------------------------------------------------------------------------

proc matMul(a, b: array[16, float32]; outM: var array[16, float32]) =
  ## outM = a * b, both Unity column-major (element (r,c) = m[c*4+r]).
  for c in 0 ..< 4:
    for r in 0 ..< 4:
      var s = 0.0'f32
      for k in 0 ..< 4:
        s = s + a[k*4 + r] * b[c*4 + k]
      outM[c*4 + r] = s

proc project(m: array[16, float32]; x, y, z: float;
             w, h: int; sx, sy: var float): bool =
  ## World point to back-buffer pixel, top-left origin. False when behind the
  ## camera.
  let cx = float(m[0])*x + float(m[4])*y + float(m[8])*z  + float(m[12])
  let cy = float(m[1])*x + float(m[5])*y + float(m[9])*z  + float(m[13])
  let cw = float(m[3])*x + float(m[7])*y + float(m[11])*z + float(m[15])
  if cw <= 0.0001:
    return false
  let ndcX = cx / cw
  let ndcY = cy / cw
  sx = (ndcX * 0.5 + 0.5) * float(w)
  sy = (1.0 - (ndcY * 0.5 + 0.5)) * float(h)
  result = true

# ---------------------------------------------------------------------------
# The bindings, held across frames
# ---------------------------------------------------------------------------

var bWorld: Binding          ## GameWorld::get_Instance, static
var bCamMain: Binding         ## UnityEngine.Camera::get_main, static
var bCamMgr: Binding          ## EFT.CameraControl.CameraManager::get_Instance
var gStaticsBound = false

var obAlive: ObjBind          ## world.get_AllAlivePlayersList
var obMain: ObjBind           ## world.get_MainPlayer
var obCount: ObjBind          ## list.get_Count
var obItem: ObjBind           ## list.get_Item(int)
var obIsAI: ObjBind           ## player.get_IsAI
var obSide: ObjBind           ## player.get_Side
var obPos: ObjBind            ## player.get_Position (shaped)
var obCamOfMgr: ObjBind       ## cameraManager.get_Camera
var obView: ObjBind           ## camera.get_worldToCameraMatrix (shaped)
var obProj: ObjBind           ## camera.get_projectionMatrix (shaped)
var obPixW: ObjBind           ## camera.get_pixelWidth
var obPixH: ObjBind           ## camera.get_pixelHeight

var gLocalSide = -1
var gCollectWhy = "not attempted"
var gLastCount = 0

const HeadHeight = 1.8   ## metres from feet to the box top

proc bindStatics(): bool =
  if gStaticsBound:
    return bWorld.ok
  bWorld = bindMethod(gRt, "EFT.GameWorld", "get_Instance", 0)
  bCamMain = bindMethod(gRt, "UnityEngine.Camera", "get_main", 0)
  bCamMgr = bindMethod(gRt, "EFT.CameraControl.CameraManager", "get_Instance", 0)
  obAlive = noObjBind(); obMain = noObjBind(); obCount = noObjBind()
  obItem = noObjBind(); obIsAI = noObjBind(); obSide = noObjBind()
  obPos = noObjBind(); obCamOfMgr = noObjBind(); obView = noObjBind()
  obProj = noObjBind(); obPixW = noObjBind(); obPixH = noObjBind()
  gStaticsBound = true
  if not bWorld.ok:
    gCollectWhy = "refused: GameWorld::get_Instance -- " & bWorld.why
  result = bWorld.ok

proc acquireCamera(): Il2CppPtr =
  ## The main camera. `Camera.main` first (a single tag lookup), then EFT's own
  ## CameraManager, whose `Camera` is what the game actually renders through.
  var a = noArgs()
  if bCamMain.ok:
    let cm = callPtr(bCamMain, nullPtr(), a)
    if cm != nil:
      return cm
  if bCamMgr.ok:
    a.reset()
    let mgr = callPtr(bCamMgr, nullPtr(), a)
    if mgr != nil and ensureCall(obCamOfMgr, mgr, "get_Camera", noKinds(), fkPtr):
      a.reset()
      return callPtr(obCamOfMgr.b, mgr, a)
  result = nullPtr()

proc buildViewProj(cam: Il2CppPtr; outM: var array[16, float32]): bool =
  ## viewProj = projection * worldToCamera.
  var view = zero16()
  var proj = zero16()
  if not readMat16(obView, cam, "get_worldToCameraMatrix", view):
    return false
  if not readMat16(obProj, cam, "get_projectionMatrix", proj):
    return false
  matMul(proj, view, outM)
  # Screen size from the camera if it will give it, else keep the last known.
  var a = noArgs()
  if ensureCall(obPixW, cam, "get_pixelWidth", noKinds(), fkI32):
    a.reset(); let w = int(callInt32(obPixW.b, cam, a))
    if w > 0: gScreenW = w
  if ensureCall(obPixH, cam, "get_pixelHeight", noKinds(), fkI32):
    a.reset(); let h = int(callInt32(obPixH.b, cam, a))
    if h > 0: gScreenH = h
  result = true

proc readSide(p: Il2CppPtr): int =
  if ensureCall(obSide, p, "get_Side", noKinds(), fkI32):
    var a = noArgs()
    return int(callInt32(obSide.b, p, a))
  result = -1

proc distance(ax, ay, az, bx, by, bz: float): float =
  let dx = ax - bx; let dy = ay - by; let dz = az - bz
  var d2 = dx*dx + dy*dy + dz*dz
  if d2 <= 0.0: return 0.0
  # No sqrt import for one number; Newton from a sane seed, as census does.
  var d = d2
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d)
    inc k
  result = d

proc collectEsp*(maxDistance: float) =
  ## One pass. Fills the snapshot the renderer reads. Read-only; writes nothing
  ## into the game.
  gEnts = @[]
  gLocalPtr = 0'u64
  if not gLive:
    gCollectWhy = "runtime not up"
    return
  if not bindStatics():
    return

  var a = noArgs()
  let world = callPtr(bWorld, nullPtr(), a)
  if world == nil:
    gCollectWhy = "no GameWorld yet (not in a raid)"
    return

  # The local player, for distances, side comparison and God mode gating.
  var lx = 0.0; var ly = 0.0; var lz = 0.0
  var haveLocal = false
  if ensureCall(obMain, world, "get_MainPlayer", noKinds(), fkPtr):
    a.reset()
    let me = callPtr(obMain.b, world, a)
    if me != nil:
      gLocalPtr = cast[uint64](me)
      gLocalSide = readSide(me)
      haveLocal = readVec3(obPos, me, lx, ly, lz)

  # The camera and its view-projection.
  let cam = acquireCamera()
  var vp = zero16()
  var haveVp = false
  if cam != nil:
    haveVp = buildViewProj(cam, vp)
  if not haveVp:
    gCollectWhy = "no camera / view-projection (positions read, none projected)"

  # The alive-player list.
  if not ensureCall(obAlive, world, "get_AllAlivePlayersList", noKinds(), fkPtr):
    gCollectWhy = "refused: get_AllAlivePlayersList -- " & obAlive.why
    return
  a.reset()
  let list = callPtr(obAlive.b, world, a)
  if list == nil:
    gCollectWhy = "alive-player list is null"
    return
  if not ensureCall(obCount, list, "get_Count", noKinds(), fkI32):
    gCollectWhy = "refused: List.get_Count -- " & obCount.why
    return
  a.reset()
  let n = int(callInt32(obCount.b, list, a))
  gLastCount = n
  if n <= 0 or n > 4096:
    gCollectWhy = "list count out of range (" & $n & ")"
    return
  var oneInt: seq[FastKind] = @[]
  oneInt.add fkI32
  if not ensureCall(obItem, list, "get_Item", oneInt, fkPtr):
    gCollectWhy = "refused: List.get_Item -- " & obItem.why
    return

  gCollectWhy = "ok"
  var i = 0
  while i < n:
    a.reset()
    addInt(a, int64(i))
    let p = callPtr(obItem.b, list, a)
    inc i
    if p == nil:
      continue
    if cast[uint64](p) == gLocalPtr:
      continue   # never box yourself

    var bx = 0.0; var by = 0.0; var bz = 0.0
    if not readVec3(obPos, p, bx, by, bz):
      continue

    var dist = 0.0
    if haveLocal:
      dist = distance(bx, by, bz, lx, ly, lz)
      if maxDistance > 0.0 and dist > maxDistance:
        continue

    var ai = false
    if ensureCall(obIsAI, p, "get_IsAI", noKinds(), fkBool):
      a.reset()
      ai = callBool(obIsAI.b, p, a)

    let side = readSide(p)

    var ent = EspEntity(cx: 0.0, top: 0.0, bottom: 0.0, distance: dist,
                        side: side, isAI: ai, onScreen: false)
    if haveVp:
      var fx = 0.0; var fy = 0.0      # feet
      var hx = 0.0; var hy = 0.0      # head
      let okFeet = project(vp, bx, by, bz, gScreenW, gScreenH, fx, fy)
      let okHead = project(vp, bx, by + HeadHeight, bz, gScreenW, gScreenH, hx, hy)
      if okFeet and okHead:
        ent.cx = (fx + hx) * 0.5
        ent.top = hy
        ent.bottom = fy
        ent.onScreen = true
    gEnts.add ent

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

proc worldDiag*(): string =
  result = "collect=" & gCollectWhy &
           "  alive=" & $gLastCount &
           "  projected=" & $gEnts.len &
           "  screen=" & $gScreenW & "x" & $gScreenH &
           (if bWorld.ok: "  GameWorld.Instance ok"
            else: "  GameWorld.Instance REFUSED")
