## The client half: finding out whether Black Division actually turned up.
##
## ---------------------------------------------------------------------------
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------------
##
## Until this file, the client half was one `info` line saying nothing could run
## on the client, and then nothing ran. Everything in that line was true about
## the *original* client half -- a prepatcher that appended six members to
## `EFT.WildSpawnType`, and a BigBrain hunt layer -- and it was being used as a
## reason to ship an inert side, which is a different claim.
##
## Black Division's whole value proposition is a squad that arrives, on the
## right maps, at a randomised point in the raid. Every part of *making* that
## happen is server data, and it is all in `bd/spawns.nim`. Whether it happened
## is a fact about a live raid, observable only in the client's process, and
## before this file nothing observed it. A squad that never spawns, a squad that
## spawns 700 m away on the far side of Streets, and a squad that spawns on top
## of the player are three completely different outcomes that all read the same
## from the server log: "spawns rebuilt on 10 map(s)".
##
## So this watches. Every few seconds it walks the world's alive-player list,
## matches each AI against Black Division's **own shipped first-name table**,
## and reports how many of its bots are alive and how far away the nearest is.
##
## ---------------------------------------------------------------------------
## WHY THE NAME AND NOT THE ROLE
## ---------------------------------------------------------------------------
##
## Because the role cannot work and the name can, and the difference is the
## whole post-1.0 story of this mod.
##
## The six role ids (`848420`..`848426`) are server-side constants. The client's
## `WildSpawnType` is native constants with its switch tables already compiled,
## there is no managed `Assembly-CSharp.dll` to rewrite and no pre-load window
## in which to do it, so a Black Division bot reaches the client wearing
## whatever base type the server mapped it onto. Matching on the role would find
## nothing, for ever, and would look exactly like the mod not working.
##
## The nicknames are different. They come out of `data/types/blackDiv.json` and
## `data/types/bossWedge.json` -- **this mod's own files**, the ones the server
## half feeds to the bot generator -- so the match is against data this mod
## controls rather than against a guess about the game. A bot generated from
## that table has one of those first names and an empty surname, which is a
## signature nothing else in the raid has.
##
## It is not a *proof* of identity: a scav could in principle roll the name
## "Anvil" if some other mod put it in a name table. The report says how many
## matched rather than asserting who they are, and the empty-surname check
## halves the remaining ambiguity. That is the honest strength of the claim and
## it is stated rather than rounded up.
##
## ---------------------------------------------------------------------------
## WHAT IT DOES NOT DO
## ---------------------------------------------------------------------------
##
## **It writes nothing into the game.** Not one field. The hunt behaviour that
## would make these bots track the player is `HuntTargetLayer` at priority 10
## over the PMC brains, which is a BigBrain custom layer hosted by a BepInEx
## that does not exist post-1.0; there is no seam to hang it on and inventing
## one by driving the bots directly from here would be re-implementing
## `mods/sain` badly and without being able to tell which bots to do it to.
## `BDNvgPatch` is likewise not resurrected: it was already dead upstream, and
## suppressing night vision for *every* bot -- which is all a patch without
## `this` could do -- is a worse outcome than leaving it alone.
##
## **Nothing here has ever run against BSG's game.** Every `EFT.` name below is
## from the pre-1.0 C# surface, and post-1.0 is a different build. A wrong one
## is a refused binding with a `why` line in the log and a watch that reports
## fewer facts, never a wrong number. `watchReport()` prints every one of them
## once.

import std/strutils
import aowlspt
import aowlspt/json
import aowlspt/il2cpp
import aowlspt/fast
import data

# ---------------------------------------------------------------------------
# The runtime
# ---------------------------------------------------------------------------

## Assigned from `openWatch()`, never at its declaration: in a nimony
## `--app:lib` build a global initialised by a *call* is silently left zeroed,
## so `var gRt = openIl2Cpp()` would produce a runtime that is never loaded and
## a watch that quietly sees nothing.
var gRt: Il2Cpp
var gLive = false

proc watchLive*(): bool = gLive

proc openWatch*(): bool =
  if gLive:
    return true
  gRt = openIl2Cpp()
  if not gRt.loaded:
    return false
  let missing = missingEssential(gRt)
  if missing.len > 0:
    warn "blackdivision: the IL2CPP runtime is missing " & $missing.len &
         " essential entry points; the watch is unavailable"
    return false
  gLive = true
  result = true

proc openWatchAt*(path, domainName: string): bool =
  ## For the self-test only: a runtime loaded from a path rather than found in
  ## the process. Out of process it is loaded but not *started*, so
  ## `il2cpp_init` is called too -- and on a real client that will very likely
  ## refuse, because the metadata is decrypted during the game's own startup.
  ## A refusal is a real answer and the caller prints it as one.
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
# Binding against the object, once per class
# ---------------------------------------------------------------------------
#
# `bindOnObject` needs an object, so the attempt lands on the scan path. That is
# fine exactly once and ruinous every scan: it walks a whole base chain. A
# *refused* binding retried per bot per scan is the worst case, because it never
# succeeds and never stops costing. So an attempt is keyed on the class it was
# made against -- one `il2cpp_object_get_class` and one pointer compare
# afterwards, whether it succeeded or not. A different class is a new question.
# That is `mods/sain`'s `LazyCall` rule, for the same reason.

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
# The value-type size convention, asked rather than assumed
# ---------------------------------------------------------------------------
#
# `il2cpp_class_get_instance_size` on a value type reports the payload plus the
# object header on the real runtime -- the same convention `il2cpp_object_unbox`
# implies, since unboxing is that header being stepped over. Hard-coding 16 for
# that header (a class pointer and a monitor pointer on x64) is the number that
# is right today, and it is exactly the sort of layout constant this repo does
# not let a mod assert: `tests/mockil2cpp` reports the payload with no header,
# and a mod that subtracted 16 there computed a negative size and refused every
# shaped call while looking like it had checked.
#
# So it is calibrated. `System.Int32` is four bytes of payload and
# `System.Double` is eight, everywhere; whatever this runtime adds to both is
# its header. If they do not differ by four, the convention is one this will not
# reason about and every shaped binding refuses -- which is the failure this
# apparatus exists to produce instead of a plausible number.

var gHeaderBytes = -1

proc calibrateHeader*() =
  if gHeaderBytes != -1:
    return
  let i32 = findClass(gRt, "System.Int32")
  let f64 = findClass(gRt, "System.Double")
  if i32 == nil or f64 == nil:
    return
  let a = classInstanceSize(gRt, i32)
  let b = classInstanceSize(gRt, f64)
  if a <= 0 or b <= 0 or b - a != 4:
    gHeaderBytes = -2
    warn "blackdivision: this runtime reports System.Int32 as " & $a &
         " bytes and System.Double as " & $b &
         "; that is not payload-plus-a-constant-header, so no shaped call " &
         "will be asserted against it"
    return
  gHeaderBytes = a - 4

proc headerBytes*(): int = gHeaderBytes

proc payloadSize*(tn: string): int =
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

proc shapedSizeAccepted*(sz: int): bool =
  ## **The Win64 rule itself**, as a function of a size and nothing else: an
  ## aggregate of 1, 2, 4 or 8 bytes goes in a general register and everything
  ## else goes through memory the caller supplies. The 16-byte ceiling is this
  ## mod's, not the ABI's -- it is the buffer `readPosition` hands over.
  ##
  ## A pure function on purpose, so that both of its branches can be exercised
  ## with no game and no stand-in runtime. A guard reachable only through a live
  ## client is one whose accepting branch may never have run, and "refused
  ## correctly" and "never reachable" look identical from outside.
  if sz <= 0: return false
  if sz == 1 or sz == 2 or sz == 4 or sz == 8: return false
  result = sz <= 16

proc shapedRetSizeOk*(tn: string): bool =
  result = shapedSizeAccepted(payloadSize(tn))

# ---------------------------------------------------------------------------
# The name table
# ---------------------------------------------------------------------------

var gNames: seq[string] = @[]
var gNamesFrom = 0

proc lowerAscii(s: string): string =
  result = ""
  for ch in s:
    if ch >= 'A' and ch <= 'Z':
      result.add char(ord(ch) + 32)
    else:
      result.add ch

proc addNamesFrom(relative: string) =
  ## The `firstName` array of one of this mod's own bot templates.
  ##
  ## Read out of the shipped file rather than duplicated into nimony source, so
  ## that editing the name table edits what the watch matches. A file that is
  ## missing costs the names in it and nothing else.
  let text = readData(relative)
  if text.len == 0:
    warn "blackdivision: " & relative & " could not be read; the watch will " &
         "not recognise the bots it names"
    return
  let names = each(field(text, "firstName"))
  var added = 0
  for n in names:
    let s = n.asText("")
    if s.len > 0:
      gNames.add lowerAscii(s)
      inc added
  if added > 0:
    inc gNamesFrom

proc loadNames*() =
  ## Both templates. `bossWedge.json` is Wedge's own; the other five share one.
  if gNames.len > 0:
    return
  addNamesFrom("types/blackDiv.json")
  addNamesFrom("types/bossWedge.json")

proc nameCount*(): int = gNames.len
proc nameFileCount*(): int = gNamesFrom

proc isOurName*(nickname: string): bool =
  ## Case-insensitive, and against the **first token only**: the game shows a
  ## nickname that may carry a surname, and Black Division's table has an empty
  ## `lastName` list, so the first token is the whole of what this mod chose.
  if nickname.len == 0 or gNames.len == 0:
    return false
  var first = nickname
  let sp = find(nickname, " ")
  if sp > 0:
    first = nickname.substr(0, sp - 1)
  let want = lowerAscii(first)
  for i in 0 ..< gNames.len:
    if gNames[i] == want:
      return true
  result = false

# ---------------------------------------------------------------------------
# The bindings
# ---------------------------------------------------------------------------

type
  WatchBindings = object
    ready: bool
    world: Binding
    worldWhy: string
    alive: ObjBind
    mainPlayer: ObjBind
    count: ObjBind
    item: ObjBind
    isAI: ObjBind
    profile: ObjBind
    info: ObjBind
    nickname: ObjBind
    position: ObjBind
    positionWhy: string

var gB: WatchBindings

proc watchBind*() =
  ## Bind what can be bound without an object; the rest binds on the first
  ## object of its class the scan meets.
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
  gB.nickname = noObjBind()
  gB.position = noObjBind()
  gB.positionWhy = "not attempted"
  gB.world = bindMethod(gRt, "EFT.GameWorld", "get_Instance", 0)
  gB.worldWhy = gB.world.why
  gB.ready = true

proc bindPosition(player: Il2CppPtr): bool =
  ## `get_Position`, by its **native slot shape** rather than its signature.
  ##
  ## A `Vector3` is twelve bytes, and Win64 returns anything larger than eight
  ## and not a power of two through a hidden pointer the caller supplies: the
  ## compiled function is `void* get_Position(void* sret, void* this,
  ## MethodInfo*)`. Two pointer slots, in that order, and no float slot -- which
  ## is why the mask is 0. That is the assertion; `shapedRetSizeOk` is what
  ## earns it, by asking the runtime whether the return really is a value type
  ## of a non-register size.
  ##
  ## A wrong slot count would not crash. It would read an uninitialised register
  ## as an argument and hand back a plausible position, which is the failure
  ## mode with the longest time-to-diagnosis available. That is why the guard is
  ## a guard and not a comment.
  if player == nil:
    return false
  if not changedClass(gB.position, player):
    return gB.position.b.ok
  gB.position.tried = true
  let cls = objectClass(gRt, player)
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
    return false
  if methodIsStatic(gRt, found):
    # The shape below puts `this` in slot 1. A static returning a struct has a
    # different shape again and nothing here is one.
    gB.positionWhy = fullName(gRt, declaring) &
                     "::get_Position is static; this shape assumes an instance"
    gB.position.b.ok = false
    return false
  let tn = typeName(gRt, methodReturnType(gRt, found))
  if not shapedRetSizeOk(tn):
    gB.positionWhy = fullName(gRt, declaring) & "::get_Position returns " & tn &
      ", which the runtime does not report as a value type of a non-register " &
      "size (payload " & $payloadSize(tn) & " bytes, header " &
      $headerBytes() & "). The hidden-return-pointer shape is refused rather " &
      "than assumed; distances are not reported."
    gB.position.b.ok = false
    return false
  gB.position.b = bindRaw(gRt, declaring, fullName(gRt, declaring),
                          "get_Position", 0, 2, 0'u32, fkPtr)
  gB.position.why = gB.position.b.why
  gB.positionWhy = gB.position.b.why & " [hidden return pointer + this; the " &
                   "runtime reports " & tn & " as " & $payloadSize(tn) &
                   " bytes]"
  result = gB.position.b.ok

proc readPosition(player: Il2CppPtr; x, y, z: var float): bool =
  ## One shaped call. `buf` is four floats rather than three so that a value
  ## type of up to sixteen bytes -- which the guard permits -- cannot write past
  ## it. The return is discarded because it *is* `buf`: the callee writes
  ## through the pointer it was handed and gives the same address back.
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

proc distanceBetween(ax, ay, az, bx, by, bz: float): float =
  let dx = bx - ax
  let dy = by - ay
  let dz = bz - az
  var d2 = dx * dx + dy * dy + dz * dz
  if d2 <= 0.0:
    return 0.0
  # Newton, rather than importing a maths module for one square root on a path
  # that runs a handful of times every few seconds.
  var d = (if d2 > 1.0: d2 else: 1.0)
  var k = 0
  while k < 24:
    d = 0.5 * (d + d2 / d)
    inc k
  result = d

# ---------------------------------------------------------------------------
# The watch
# ---------------------------------------------------------------------------

type
  Sighting* = object
    ok*: bool           ## a world existed and the list was walked
    aiAlive*: int
    ours*: int          ## AI whose nickname is in this mod's own table
    unreadable*: int    ## AI whose nickname would not read
    haveDistance*: bool
    nearest*: float
    scanNs*: int64
    names*: seq[string]

proc emptySighting*(): Sighting =
  Sighting(ok: false, aiAlive: 0, ours: 0, unreadable: 0, haveDistance: false,
           nearest: 0.0, scanNs: 0'i64, names: @[])

const MaxNamed = 12
  ## How many matched nicknames are carried in the report. Past that the count
  ## is the fact and the list is noise.

proc runWatch*(): Sighting =
  result = emptySighting()
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

  # `List<T>` is a generic instantiation with no name `findClass` accepts, so
  # binding on the instance is the only way to reach it at all. `get_Item`'s
  # shape -- one integer in, one reference out -- is stated rather than
  # inferred, because inference would have to name the declaring type.
  if not ensureCall(gB.count, list, "get_Count", none, fkI32):
    return
  a.reset()
  let n = int(callInt32(gB.count.b, list, a))
  result.ok = true
  if n <= 0 or n > 4096:
    result.scanNs = nanosBetween(t0, perfCounter())
    return
  var oneInt: seq[FastKind] = @[]
  oneInt.add fkI32
  if not ensureCall(gB.item, list, "get_Item", oneInt, fkPtr):
    return

  var px = 0.0
  var py = 0.0
  var pz = 0.0
  var havePlayer = false
  if ensureCall(gB.mainPlayer, world, "get_MainPlayer", none, fkPtr):
    a.reset()
    let me = callPtr(gB.mainPlayer.b, world, a)
    if me != nil:
      havePlayer = readPosition(me, px, py, pz)

  var i = 0
  while i < n:
    a.reset()
    addInt(a, int64(i))
    let p = callPtr(gB.item.b, list, a)
    inc i
    if p == nil:
      continue
    if not ensureCall(gB.isAI, p, "get_IsAI", none, fkBool):
      continue
    a.reset()
    if not callBool(gB.isAI.b, p, a):
      continue
    result.aiAlive = result.aiAlive + 1

    # Profile -> Info -> Nickname. Bound against the objects, because `Info` is
    # a nested type on some builds and a nested type is `Info` with the outer
    # type's namespace as far as the C API is concerned -- so no qualified name
    # reaches it.
    var nick = ""
    a.reset()
    if ensureCall(gB.profile, p, "get_Profile", none, fkPtr):
      a.reset()
      let prof = callPtr(gB.profile.b, p, a)
      if prof != nil and ensureCall(gB.info, prof, "get_Info", none, fkPtr):
        a.reset()
        let inf = callPtr(gB.info.b, prof, a)
        if inf != nil and ensureCall(gB.nickname, inf, "get_Nickname", none,
                                     fkPtr):
          a.reset()
          let sp = callPtr(gB.nickname.b, inf, a)
          if sp != nil:
            nick = readString(gRt, sp)
    if nick.len == 0:
      result.unreadable = result.unreadable + 1
      continue
    if not isOurName(nick):
      continue
    result.ours = result.ours + 1
    if result.names.len < MaxNamed:
      result.names.add nick
    if havePlayer:
      var bx = 0.0
      var by = 0.0
      var bz = 0.0
      if readPosition(p, bx, by, bz):
        let d = distanceBetween(px, py, pz, bx, by, bz)
        if not result.haveDistance:
          result.haveDistance = true
          result.nearest = d
        elif d < result.nearest:
          result.nearest = d
  result.scanNs = nanosBetween(t0, perfCounter())

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

proc reportOne(label: string; o: ObjBind) =
  if o.b.ok:
    info "blackdivision:   fast     " & label & " -- " & o.why
  elif o.tried:
    warn "blackdivision:   REFUSED  " & label & " -- " & o.why
  else:
    debug "blackdivision:   unused   " & label & " (no object of that class yet)"

proc watchReport*() =
  ## Every binding's own account of itself, once.
  ##
  ## docs/PERF.md asks for exactly this: a refused binding is a mod that quietly
  ## does nothing otherwise. "No Black Division bots are alive" and "the watch
  ## could not read a nickname" are different facts and this is the only thing
  ## that tells them apart.
  info "blackdivision: watch bindings --"
  if gB.world.ok:
    info "blackdivision:   fast     GameWorld::get_Instance -- " & gB.worldWhy
  else:
    warn "blackdivision:   REFUSED  GameWorld::get_Instance -- " & gB.worldWhy
  reportOne("GameWorld::get_AllAlivePlayersList", gB.alive)
  reportOne("GameWorld::get_MainPlayer", gB.mainPlayer)
  reportOne("List<IPlayer>::get_Count", gB.count)
  reportOne("List<IPlayer>::get_Item", gB.item)
  reportOne("Player::get_IsAI", gB.isAI)
  reportOne("Player::get_Profile", gB.profile)
  reportOne("Profile::get_Info", gB.info)
  reportOne("Info::get_Nickname", gB.nickname)
  if gB.position.b.ok:
    info "blackdivision:   shaped   Player::get_Position -- " & gB.positionWhy
  elif gB.position.tried:
    warn "blackdivision:   REFUSED  Player::get_Position -- " & gB.positionWhy
  else:
    debug "blackdivision:   unused   Player::get_Position (no player yet)"
  info "blackdivision:   name table: " & $nameCount() & " first name(s) from " &
       $nameFileCount() & " of this mod's own template file(s)"

proc describe*(s: Sighting): string =
  if not s.ok:
    return "no world (the watch reports only inside a raid)"
  result = $s.ours & " Black Division bot(s) alive of " & $s.aiAlive & " AI"
  if s.haveDistance:
    result = result & ", nearest " & $int(s.nearest) & " m"
  if s.unreadable > 0:
    result = result & "; " & $s.unreadable & " AI with an unreadable nickname"
  result = result & "; scanned in " & $s.scanNs & " ns"
