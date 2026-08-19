## The client half: counting the bots that actually arrived.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## Until this file, MoreBots' client half was one `info` line saying that
## nothing could run on the client, and then nothing ran. That line was true
## about the *original* client half -- the prepatcher that appended members to
## `EFT.WildSpawnType` and the nine Harmony patches -- and it was being used as
## a reason to do nothing at all, which is a different claim and a false one.
##
## The question MoreBots exists to answer is "did the bots I asked for actually
## show up?", and on this side of the ABI that question is answerable. The
## server writes spawn tables and bot caps; whether the client honoured them is
## a fact about a live raid, and the only place it can be observed is in the
## client's process. So that is what this does: once every few seconds it walks
## the world's alive-player list, counts the AI, reads each one's spawn type and
## distance from the player, and reports.
##
## It is a **read-only** census. It moves no bot, changes no hostility and
## writes nothing into the game. Everything MoreBots would want to *change* on
## the client still needs the enum extension that post-1.0 has no mechanism for,
## and that is still stated plainly. What has changed is that the mod now tells
## you what happened instead of telling you that it cannot.
##
## Three things it settles that nothing else can:
##
##  * **The cap.** A server that raised `maxBotCap` to 40 and a client that
##    holds 22 alive is the single most common MoreBots complaint, and the two
##    numbers have never been in the same log line before.
##  * **The spawn distance.** A squad that spawns 600 m from the player is a
##    squad the player will never meet; that reads as "the mod does nothing".
##  * **Whether a custom spawn type reached the client at all.** It cannot --
##    see the module comment in `morebots.nim` -- and this is the observation
##    rather than the assertion. If a role id outside BSG's own range is ever
##    seen here, that claim is wrong and this is where it would show.
##
## ---------------------------------------------------------------------------
## HOW IT REACHES THE GAME
## ---------------------------------------------------------------------------
##
## Through `aowlspt/fast`, not through the host. A census of forty bots is forty
## `IsAI` reads, forty spawn-type reads and forty positions -- 120 calls -- and
## on the boxed path that is 120 microseconds of marshalling for a diagnostic.
## Bound, it is about a microsecond. `docs/PERF.md` is the whole argument.
##
## Everything except the world's static `get_Instance` is bound **against the
## object it is reached on**, because a bound call is non-virtual by
## construction and this chain is nothing but subclasses and generics: SPT's
## raid world is a `GameWorld` subclass, the alive-player list is a
## `List<IPlayer>` that `findClass` cannot name at all, and bots and the local
## player are different `Player` subclasses.
##
## Two things are **asserted** rather than inferred, and both are guarded by
## asking the runtime first:
##
##  * `get_Position` returns a `UnityEngine.Vector3`, which `bindMethod`
##    correctly refuses -- 12 bytes is not a register class. Win64 returns it
##    through a hidden pointer the caller supplies, so the compiled function is
##    `void* get_Position(void* sret, void* this, MethodInfo*)` and `bindRaw`
##    says so. `shapedRetOk` confirms from the runtime that the return type
##    really is a value type of a non-register size before that shape is
##    claimed, and refuses otherwise. This is `mods/sain`'s `tryShaped`
##    discipline, and the guard is the whole of it.
##  * `WildSpawnType` is an enum, and `classifyType` refuses every enum because
##    the C API does not say which integer width backs it. `enumRetOk` asks
##    whether the type is a value type whose payload is exactly four bytes, and
##    only then is `fkI32` asserted.
##
## Every refusal keeps the census running on what it could read. A bot whose
## spawn type will not bind is counted as a bot with an unknown type, not
## dropped and not invented.
##
## **Nothing in this file has ever run against BSG's game.** Every `EFT.` name
## below is from the pre-1.0 C# surface, and post-1.0 is a different build. A
## wrong one is a refused binding with a `why` line in the log and a census that
## reports fewer facts, never a wrong number. `censusReport()` prints every one
## of them once.

import aowlspt
import aowlspt/il2cpp
import aowlspt/fast

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------

## Assigned from `openCensus()`, never at its declaration: in a nimony
## `--app:lib` build a global initialised by a *call* is silently left zeroed,
## so `var gRt = openIl2Cpp()` would produce a runtime that is never loaded and
## a census that quietly counts nothing.
var gRt: Il2Cpp
var gLive = false

proc censusLive*(): bool = gLive

proc openCensus*(): bool =
  ## Binds `GameAssembly.dll` if it is in the process. Cheap to call again once
  ## it has succeeded; retried while it has not, because "the game has not got
  ## that far yet" and "this is not the game" look the same from here and only
  ## one of them is final.
  if gLive:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  let missing = missingEssential(gRt)
  if missing.len > 0:
    warn "morebots: the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the census is unavailable"
    return false
  gLive = true
  result = true

proc openCensusAt*(path: string; domainName: string): bool =
  ## The same, against a runtime loaded from a path rather than found in the
  ## process. Only the self-test uses this: out of process the runtime is
  ## loaded but not *started*, so `il2cpp_init` is called too, and on a real
  ## client that will very likely refuse because the metadata is decrypted
  ## during the game's own startup. A refusal is a real answer and the caller
  ## prints it as one.
  if gLive:
    return true
  gRt = openIl2Cpp(path)
  if not gRt.loaded:
    return false
  if gRt.has(eInit):
    discard gRt.init(domainName)
  gLive = true
  result = true

# ---------------------------------------------------------------------------
# Binding against the object, once
# ---------------------------------------------------------------------------
#
# `bindOnObject` needs an object, so it cannot happen before the raid -- which
# puts the attempt on the scan path. That is fine exactly once and ruinous every
# scan: it walks a whole base chain, measured in microseconds. A *refused*
# binding retried per bot per scan is the worst case, because it never succeeds
# and never stops costing.
#
# So an attempt is keyed on the class it was made against: one
# `il2cpp_object_get_class` and one pointer compare afterwards, whether the bind
# succeeded or not. A different class -- a scav where the last one was a PMC --
# is a new question and is asked again. That is `mods/sain`'s `LazyCall` rule.

type
  ObjBind* = object
    b*: Binding
    cls: Il2CppClass
    tried*: bool
    why*: string

proc noObjBind*(): ObjBind =
  ObjBind(b: Binding(ok: false, why: "", target: "", fn: nullPtr(),
                     info: nullPtr(), argc: 0'i32, slots: 0'i32, mask: 0'u32,
                     ret: fkNone, isStatic: false, bindNs: 0'i64),
          cls: cast[Il2CppClass](0), tried: false, why: "not attempted")

proc changedClass(o: var ObjBind; obj: Il2CppPtr): bool =
  ## True when this member has not yet been asked about the class `obj` is.
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
  ## An empty argument list for `bindOnObject`. A bare `[]` literal has no type
  ## for nimony to infer at that call site, so the empty seq is named once.
  result = @[]

# ---------------------------------------------------------------------------
# The two assertions, and the guards that earn them
# ---------------------------------------------------------------------------

# How this runtime reports a value type's size, asked rather than assumed.
#
# `il2cpp_class_get_instance_size` on a *value* type reports the payload plus
# the object header on the real runtime -- the same convention
# `il2cpp_object_unbox` implies, since unboxing is that header being stepped
# over. A hard-coded 16 for the header (a class pointer and a monitor pointer on
# x64) is the number that is right today, and it is exactly the kind of layout
# constant this repo does not let a mod assert: `tests/mockil2cpp` reports the
# payload with no header at all, and a mod that subtracted 16 there computed a
# negative size and refused every shaped call while looking like it had checked.
#
# So it is calibrated. `System.Int32` is four bytes of payload and
# `System.Double` is eight, on every build there has ever been; whatever this
# runtime adds to both is its header. Two knowns and a difference, and the
# header falls out. If the two do not differ by four, the convention is one this
# will not reason about and **every** shaped or asserted binding refuses -- which
# is the failure this whole apparatus exists to produce instead of a plausible
# number.

var gHeaderBytes = -1
  ## -1: not yet asked. -2: asked, and the answer made no sense.

proc calibrateHeader*() =
  if gHeaderBytes != -1:
    return
  let i32 = findClass(gRt, "System.Int32")
  let f64 = findClass(gRt, "System.Double")
  if i32 == nil or f64 == nil:
    # Leave it at -1: the assemblies may simply not be up yet, and this is
    # retried. Until then every guarded binding refuses.
    return
  let a = classInstanceSize(gRt, i32)
  let b = classInstanceSize(gRt, f64)
  if a <= 0 or b <= 0 or b - a != 4:
    gHeaderBytes = -2
    warn "morebots: this runtime reports System.Int32 as " & $a &
         " bytes and System.Double as " & $b &
         ", which is not payload-plus-a-constant-header. No shaped call and " &
         "no enum width will be asserted against it."
    return
  gHeaderBytes = a - 4
  debug "morebots: value-type instance sizes include a " & $gHeaderBytes &
        "-byte header on this runtime (System.Int32 reports " & $a & ")"

proc headerBytes*(): int = gHeaderBytes

proc payloadSize*(tn: string): int =
  ## The payload size of a value type, or 0 when the type is a reference, is
  ## unknown, or comes back at a size this will not reason about.
  result = 0
  if tn.len == 0:
    return
  calibrateHeader()
  if gHeaderBytes < 0:
    return
  let c = findClass(gRt, tn)
  if c == nil:
    return
  if not classIsValueType(gRt, c):
    return
  let sz = classInstanceSize(gRt, c) - gHeaderBytes
  if sz <= 0 or sz > 64:
    return
  result = sz

proc shapedRetOk(m: Il2CppMethod; size: var int): bool =
  ## Whether this method's return really is an aggregate Win64 hands back
  ## through a hidden pointer.
  ##
  ## The rule is the ABI's, not this mod's: an aggregate of 1, 2, 4 or 8 bytes
  ## comes back in a register; everything else goes to memory the caller
  ## supplies. Nothing here is keyed off the name `Vector3` -- the runtime is
  ## asked whether the type is a value type and how big it is, and a size that
  ## would fit in a register refuses the shape outright.
  size = 0
  if m == nil:
    return false
  if methodIsStatic(gRt, m):
    # The shape below puts `this` in slot 1. A static returning a struct has a
    # different shape again and nothing here is one.
    return false
  let tn = typeName(gRt, methodReturnType(gRt, m))
  # Anything wider than sixteen bytes is refused too, because that is the buffer
  # `readPosition` provides; refusing beats writing past it.
  if not shapedRetSizeOk(tn):
    return false
  size = payloadSize(tn)
  result = true

proc shapedSizeAccepted*(sz: int): bool =
  ## **The Win64 rule itself**, as a function of a size and nothing else.
  ##
  ## An aggregate of 1, 2, 4 or 8 bytes is passed and returned in a general
  ## register; everything else goes through memory the caller supplies. The
  ## upper bound of 16 is this mod's, not the ABI's: it is the size of the
  ## buffer `readPosition` hands over, and refusing beats writing past it.
  ##
  ## Split out as a pure function on purpose. A guard that is only reachable
  ## through a live runtime is a guard whose accepting branch may never have run
  ## -- and "refused correctly" and "never reachable" look identical from
  ## outside. This one can be, and is, exercised exhaustively over every size it
  ## will ever see, with no game and no stand-in runtime involved.
  if sz <= 0: return false
  if sz == 1 or sz == 2 or sz == 4 or sz == 8: return false
  result = sz <= 16

proc shapedRetSizeOk*(tn: string): bool =
  ## The same rule applied to a *type*, which is the half that needs the
  ## runtime: is it a value type, and how big is its payload.
  result = shapedSizeAccepted(payloadSize(tn))

proc enumSizeOk*(tn: string): bool =
  ## Whether a type is a four-byte value type -- the only case in which
  ## asserting `fkI32` for an enum is safe. Same split, same reason.
  result = payloadSize(tn) == 4

proc enumRetOk(m: Il2CppMethod): bool =
  ## Whether this method's return is a value type of exactly four bytes -- which
  ## is what an `Int32`-backed enum is, and is the only case in which asserting
  ## `fkI32` for it is safe.
  ##
  ## `classifyType` refuses every enum, and it is right to: the C API says
  ## nothing about which integer backs one, and `long` enums exist. Asking for
  ## the size is what turns "probably an int" into an answer.
  if m == nil:
    return false
  result = enumSizeOk(typeName(gRt, methodReturnType(gRt, m)))

# ---------------------------------------------------------------------------
# The bindings
# ---------------------------------------------------------------------------

type
  CensusBindings = object
    ready: bool
    world: Binding          ## EFT.GameWorld::get_Instance, static, by name
    worldWhy: string
    alive: ObjBind          ## on the world object
    mainPlayer: ObjBind     ## on the world object
    count: ObjBind          ## on the list -- a generic with no nameable class
    item: ObjBind           ## on the list, [fkI32] -> fkPtr, stated
    isAI: ObjBind           ## on a player
    profile: ObjBind        ## on a player
    info: ObjBind           ## on a profile
    settings: ObjBind       ## on an info
    role: ObjBind           ## on a settings -- an enum, asserted as fkI32
    roleWhy: string
    position: ObjBind       ## on a player -- Vector3, shaped
    positionWhy: string

var gB: CensusBindings

proc censusBind*() =
  ## Bind what can be bound without an object. Everything else is bound on the
  ## first object of its class the scan meets.
  ##
  ## Never from `onLoad`: `findClass` walks every loaded assembly and the game's
  ## are not among them then, so a binding made there would correctly refuse and
  ## never be retried.
  if gB.ready:
    return
  gB.alive = noObjBind()
  gB.mainPlayer = noObjBind()
  gB.count = noObjBind()
  gB.item = noObjBind()
  gB.isAI = noObjBind()
  gB.profile = noObjBind()
  gB.info = noObjBind()
  gB.settings = noObjBind()
  gB.role = noObjBind()
  gB.position = noObjBind()
  gB.roleWhy = "not attempted"
  gB.positionWhy = "not attempted"
  gB.world = bindMethod(gRt, "EFT.GameWorld", "get_Instance", 0)
  gB.worldWhy = gB.world.why
  gB.ready = true

proc bindRole(player: Il2CppPtr; settings: Il2CppPtr): bool =
  ## `get_Role`, asserted as a four-byte enum after the runtime has confirmed
  ## the size. Bound against the settings object because the settings class is
  ## a nested type on some builds and `findClass` cannot name a nested type.
  if settings == nil:
    return false
  if not changedClass(gB.role, settings):
    return gB.role.b.ok
  gB.role.tried = true
  var cls = objectClass(gRt, settings)
  var found: Il2CppMethod = cast[Il2CppMethod](0)
  var declaring: Il2CppClass = cast[Il2CppClass](0)
  var c = cls
  while c != nil:
    let m = findMethod(gRt, c, "get_Role", 0)
    if m != nil:
      found = m
      declaring = c
      break
    c = classParent(gRt, c)
  if found == nil:
    gB.roleWhy = "no get_Role on " & fullName(gRt, cls) &
                 " or any of its base classes"
    gB.role.b.ok = false
    gB.role.why = gB.roleWhy
    return false
  if not enumRetOk(found):
    gB.roleWhy = fullName(gRt, declaring) & "::get_Role returns " &
      typeName(gRt, methodReturnType(gRt, found)) &
      ", which is not a four-byte value type. This will not assert an " &
      "integer width the runtime did not confirm; spawn types are reported " &
      "as unknown."
    gB.role.b.ok = false
    gB.role.why = gB.roleWhy
    return false
  var none = noKinds()
  gB.role.b = bindInClass(gRt, declaring, fullName(gRt, declaring), "get_Role",
                          none, fkI32)
  gB.role.why = gB.role.b.why
  gB.roleWhy = gB.role.b.why & " [enum asserted as Int32; the runtime " &
               "confirmed a four-byte value type]"
  result = gB.role.b.ok

proc bindPosition(player: Il2CppPtr): bool =
  ## `get_Position`, by its **native slot shape** rather than its signature.
  ##
  ## A `Vector3` is twelve bytes, and Win64 returns anything larger than eight
  ## and not a power of two through a hidden pointer the caller supplies: the
  ## compiled function is `void* get_Position(void* sret, void* this,
  ## MethodInfo*)`. Two pointer slots, in that order, no float slot -- which is
  ## why the mask is 0. That is the assertion, and `shapedRetOk` above is what
  ## earns it: the runtime is asked whether the return is a value type and how
  ## big it is, and a register-sized one refuses the shape.
  ##
  ## Getting a slot count wrong here would not crash; it would read an
  ## uninitialised register as an argument and hand back a plausible position.
  ## That is why the guard is a guard and not a comment.
  if player == nil:
    return false
  if not changedClass(gB.position, player):
    return gB.position.b.ok
  gB.position.tried = true
  var cls = objectClass(gRt, player)
  var found: Il2CppMethod = cast[Il2CppMethod](0)
  var declaring: Il2CppClass = cast[Il2CppClass](0)
  var c = cls
  while c != nil:
    let m = findMethod(gRt, c, "get_Position", 0)
    if m != nil:
      found = m
      declaring = c
      break
    c = classParent(gRt, c)
  if found == nil:
    gB.positionWhy = "no get_Position on " & fullName(gRt, cls) &
                     " or any of its base classes"
    gB.position.b.ok = false
    gB.position.why = gB.positionWhy
    return false
  var size = 0
  if not shapedRetOk(found, size):
    gB.positionWhy = fullName(gRt, declaring) & "::get_Position returns " &
      typeName(gRt, methodReturnType(gRt, found)) &
      ", which the runtime does not report as a value type of a " &
      "non-register size. The hidden-return-pointer shape is refused rather " &
      "than assumed; distances are not reported."
    gB.position.b.ok = false
    gB.position.why = gB.positionWhy
    return false
  gB.position.b = bindRaw(gRt, declaring, fullName(gRt, declaring),
                          "get_Position", 0, 2, 0'u32, fkPtr)
  gB.position.why = gB.position.b.why
  gB.positionWhy = gB.position.b.why & " [hidden return pointer + this; the " &
                   "runtime reports the return as " & $size & " bytes]"
  result = gB.position.b.ok

proc readPosition(player: Il2CppPtr; x, y, z: var float): bool =
  ## One shaped call. `buf` is four floats rather than three so that a value
  ## type of up to sixteen bytes -- which `shapedRetOk` permits -- cannot write
  ## past it. The return value is discarded because it *is* `buf`: the callee
  ## writes through the pointer it was handed and gives the same address back.
  x = 0.0
  y = 0.0
  z = 0.0
  if not bindPosition(player):
    return false
  var buf: array[4, float32] = [0.0'f32, 0.0'f32, 0.0'f32, 0.0'f32]
  var s = shaped()
  addSlotPtr(s, cast[Il2CppPtr](addr buf[0]))
  addSlotPtr(s, player)
  discard callShapedPtr(gB.position.b, s)
  x = float(buf[0])
  y = float(buf[1])
  z = float(buf[2])
  result = true

# ---------------------------------------------------------------------------
# The census
# ---------------------------------------------------------------------------

const
  MaxRoles = 24
    ## How many distinct spawn types are tallied separately. Past that a role
    ## lands in the overflow count rather than growing a table on the scan path.

type
  Census* = object
    ok*: bool             ## a world existed and the list was walked
    total*: int           ## every alive player, human included
    ai*: int              ## how many of them the game calls AI
    withRole*: int        ## how many had a readable spawn type
    customRoles*: int     ## spawn types outside BSG's own range
    unreadable*: int      ## AI whose spawn type would not bind
    roleIds*: seq[int]
    roleCounts*: seq[int]
    overflowRoles*: int
    haveDistance*: bool
    nearest*: float
    farthest*: float
    scanNs*: int64

proc emptyCensus*(): Census =
  Census(ok: false, total: 0, ai: 0, withRole: 0, customRoles: 0,
         unreadable: 0, roleIds: @[], roleCounts: @[], overflowRoles: 0,
         haveDistance: false, nearest: 0.0, farthest: 0.0, scanNs: 0'i64)

proc tally(c: var Census; role: int) =
  for i in 0 ..< c.roleIds.len:
    if c.roleIds[i] == role:
      c.roleCounts[i] = c.roleCounts[i] + 1
      return
  if c.roleIds.len >= MaxRoles:
    c.overflowRoles = c.overflowRoles + 1
    return
  c.roleIds.add role
  c.roleCounts.add 1

const VanillaRoleCeiling = 100
  ## Every `WildSpawnType` BSG ships is a small ordinal; MoreBotsAPI's own
  ## convention puts custom ids far above it (Black Division's start at
  ## 848420). A role at or past this is therefore a *custom* type that reached
  ## the client -- which the module comment in `morebots.nim` says cannot
  ## happen post-1.0. Counting them is how that claim gets tested rather than
  ## repeated.

proc runCensus*(): Census =
  ## One pass over the world's alive players. Called at whatever interval the
  ## caller chooses; nothing here is per-frame, and nothing here writes.
  result = emptyCensus()
  if not gLive or not gB.ready or not gB.world.ok:
    return
  let t0 = perfCounter()
  var none = noKinds()

  var a = noArgs()
  let world = callPtr(gB.world, nullPtr(), a)
  if world == nil:
    return

  if not ensureCall(gB.alive, world, "get_AllAlivePlayersList", none, fkPtr):
    return
  a.reset()
  let list = callPtr(gB.alive.b, world, a)
  if list == nil:
    return

  # `List<T>` is a generic instantiation: it has no name `findClass` accepts,
  # and binding on the instance is the only way to reach it at all. `get_Item`'s
  # signature is one integer in and one reference out -- a shape the fast path
  # covers -- so it is *stated* rather than inferred, because the inference
  # would have to name the declaring type to classify it.
  if not ensureCall(gB.count, list, "get_Count", none, fkI32):
    return
  a.reset()
  let n = int(callInt32(gB.count.b, list, a))
  if n <= 0 or n > 4096:
    result.ok = true
    result.scanNs = nanosBetween(t0, perfCounter())
    return
  var oneInt: seq[FastKind] = @[]
  oneInt.add fkI32
  if not ensureCall(gB.item, list, "get_Item", oneInt, fkPtr):
    return

  # The local player, for the distances. Its absence is not a failure: a census
  # without distances is still a census, and it says so.
  var px = 0.0
  var py = 0.0
  var pz = 0.0
  var havePlayer = false
  if ensureCall(gB.mainPlayer, world, "get_MainPlayer", none, fkPtr):
    a.reset()
    let me = callPtr(gB.mainPlayer.b, world, a)
    if me != nil:
      havePlayer = readPosition(me, px, py, pz)

  result.ok = true
  var i = 0
  while i < n:
    a.reset()
    addInt(a, int64(i))
    let p = callPtr(gB.item.b, list, a)
    inc i
    if p == nil:
      continue
    result.total = result.total + 1
    if not ensureCall(gB.isAI, p, "get_IsAI", none, fkBool):
      continue
    a.reset()
    if not callBool(gB.isAI.b, p, a):
      continue
    result.ai = result.ai + 1

    # Profile -> Info -> Settings -> Role. Every step bound against the object,
    # because `Info` and `Settings` are nested types on some builds and a
    # nested type is `Settings` with the outer type's namespace as far as the C
    # API is concerned -- so no qualified name reaches them.
    var role = -1
    a.reset()
    if ensureCall(gB.profile, p, "get_Profile", none, fkPtr):
      a.reset()
      let prof = callPtr(gB.profile.b, p, a)
      if prof != nil and ensureCall(gB.info, prof, "get_Info", none, fkPtr):
        a.reset()
        let inf = callPtr(gB.info.b, prof, a)
        if inf != nil and ensureCall(gB.settings, inf, "get_Settings", none,
                                     fkPtr):
          a.reset()
          let st = callPtr(gB.settings.b, inf, a)
          if st != nil and bindRole(p, st):
            a.reset()
            role = int(callInt32(gB.role.b, st, a))
    if role < 0:
      result.unreadable = result.unreadable + 1
    else:
      result.withRole = result.withRole + 1
      tally(result, role)
      if role >= VanillaRoleCeiling:
        result.customRoles = result.customRoles + 1

    if havePlayer:
      var bx = 0.0
      var by = 0.0
      var bz = 0.0
      if readPosition(p, bx, by, bz):
        let dx = bx - px
        let dy = by - py
        let dz = bz - pz
        var d2 = dx * dx + dy * dy + dz * dz
        if d2 < 0.0:
          d2 = 0.0
        # No `sqrt` import for one number: ten Newton steps from a sane seed
        # converge well past the precision a distance report needs, and pulling
        # in the maths module for this would be the tail wagging the dog.
        var d = d2
        if d > 1.0:
          var k = 0
          while k < 20:
            d = 0.5 * (d + d2 / d)
            inc k
        elif d2 > 0.0:
          d = d2
          var k = 0
          while k < 20:
            d = 0.5 * (d + d2 / d)
            inc k
        else:
          d = 0.0
        if not result.haveDistance:
          result.haveDistance = true
          result.nearest = d
          result.farthest = d
        else:
          if d < result.nearest: result.nearest = d
          if d > result.farthest: result.farthest = d
  result.scanNs = nanosBetween(t0, perfCounter())

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc reportOne(label: string; o: ObjBind) =
  if o.b.ok:
    info "morebots:   fast     " & label & " -- " & o.why
  elif o.tried:
    warn "morebots:   REFUSED  " & label & " -- " & o.why
  else:
    debug "morebots:   unused   " & label & " (no object of that class yet)"

proc censusReport*() =
  ## Every binding's own account of itself.
  ##
  ## docs/PERF.md asks for exactly this: read the binding's `why` into the log
  ## once, because "a refused binding is a mod that will quietly do nothing
  ## otherwise". A census that reports zero bots and a census that could not
  ## read the list are different facts and this is the only thing that tells
  ## them apart.
  info "morebots: census bindings --"
  if gB.world.ok:
    info "morebots:   fast     GameWorld::get_Instance -- " & gB.worldWhy
  else:
    warn "morebots:   REFUSED  GameWorld::get_Instance -- " & gB.worldWhy
  reportOne("GameWorld::get_AllAlivePlayersList", gB.alive)
  reportOne("GameWorld::get_MainPlayer", gB.mainPlayer)
  reportOne("List<IPlayer>::get_Count", gB.count)
  reportOne("List<IPlayer>::get_Item", gB.item)
  reportOne("Player::get_IsAI", gB.isAI)
  reportOne("Player::get_Profile", gB.profile)
  reportOne("Profile::get_Info", gB.info)
  reportOne("Info::get_Settings", gB.settings)
  if gB.role.b.ok:
    info "morebots:   asserted Settings::get_Role -- " & gB.roleWhy
  elif gB.role.tried:
    warn "morebots:   REFUSED  Settings::get_Role -- " & gB.roleWhy
  else:
    debug "morebots:   unused   Settings::get_Role (no settings object yet)"
  if gB.position.b.ok:
    info "morebots:   shaped   Player::get_Position -- " & gB.positionWhy
  elif gB.position.tried:
    warn "morebots:   REFUSED  Player::get_Position -- " & gB.positionWhy
  else:
    debug "morebots:   unused   Player::get_Position (no player object yet)"

proc describe*(c: Census; cap: int): string =
  ## One line, and the one line somebody actually reads.
  if not c.ok:
    return "no world (the census binds in a raid and reports nothing outside " &
           "one)"
  result = $c.ai & " AI alive of " & $c.total & " players"
  if cap > 0:
    result = result & ", against a configured cap of " & $cap
    if c.ai > cap:
      result = result & " -- OVER"
  if c.haveDistance:
    result = result & "; nearest " & $int(c.nearest) & " m, farthest " &
             $int(c.farthest) & " m"
  if c.unreadable > 0:
    result = result & "; " & $c.unreadable & " with an unreadable spawn type"
  result = result & "; scanned in " & $c.scanNs & " ns"

proc reportRoles*(c: Census) =
  if not c.ok:
    return
  if c.roleIds.len == 0:
    info "morebots:   no spawn type was readable on any alive bot"
    return
  var line = "morebots:   spawn types alive:"
  for i in 0 ..< c.roleIds.len:
    line = line & " " & $c.roleIds[i] & "x" & $c.roleCounts[i]
  if c.overflowRoles > 0:
    line = line & " (+" & $c.overflowRoles & " past the " & $MaxRoles &
           " tallied)"
  info line
  if c.customRoles > 0:
    success "morebots:   " & $c.customRoles & " bot(s) carry a spawn type at " &
            "or above " & $VanillaRoleCeiling & " -- a CUSTOM type reached " &
            "the client. That contradicts what this mod's module comment " &
            "says is possible post-1.0 and is worth reporting upstream."
  else:
    info "morebots:   no custom spawn type reached the client, which is what " &
         "the module comment predicts: WildSpawnType is native constants with " &
         "its switch tables already compiled, and nothing can append to it"
