## The client bridge: reading a bot, and driving it.
##
## `core/` is pure, `preset/` reads a config file, `server/` talks to a
## database. This file and `live.nim` are the only two that know Tarkov exists,
## deliberately, because they are also the part most likely to break against a
## client update and the part that cannot be tested offline.
##
## ## What changed, and what that means
##
## This file used to say that per-bot state could not be reached at all: the
## host resolved types and called members, but a call returning a reference
## reported `{"type":"EFT.Player"}` and no handle, so there was no route from
## `GameWorld` to a `BotOwner`. That is gone. Two things replaced it:
##
##  * The host now hands back a live object for a reference return, which is
##    what makes the *spawn hook* useful -- see `sain.nim`.
##  * `aowlspt/fast` lets a mod bind a method or a field once and then call it
##    for ~10 ns, or read it for ~2 ns, against ~1000 ns for the host's boxed
##    path. `live.nim` is that binding layer.
##
## So the bridge now walks the graph itself: world -> alive players -> the
## bot's `Player` -> `AIData` -> `BotOwner` -> the components SAIN reads. What
## it *caches* is one IL2CPP GC handle per bot, on the `Player`, held for as
## long as the bot lives.
##
## **Why one handle rather than eight.** The obvious cache is a handle per
## component: player, owner, health, movement, weapon, memory, steering, mover.
## Eight handles means eight `il2cpp_gc_handle_get_target` calls per bot per
## tick to turn them back into pointers. Re-deriving the components from the
## `Player` pointer instead is six *bound property calls* -- ~10 ns each, no
## allocation, and always current, because a component the game replaced
## mid-raid is picked up rather than pinned. Fewer handles is both cheaper and
## more correct here, which does not happen often enough to pass up.
##
## ## Performance rules this file follows
##
##  1. **Bind once.** Every member goes through `live.LazyCall`, which resolves
##     on first use against the object's own class and then costs a pointer
##     compare. Binding is 3-9 us and happens once per class.
##  2. **Resolve the handle once per tick, not per read.** `liveOf` turns the
##     bot's GC handle into this frame's pointer once; `readSelf` and `apply`
##     both take the result.
##  3. **Read once per bot per decision, not per check.** `readSelf` does one
##     pass into a plain struct and the ladder then runs entirely on stack
##     memory. SAIN's C# reads a property inside each check.
##  4. **Prefer being told over asking.** The spawn hook in `sain.nim` costs
##     nothing between spawns; polling for new bots costs the same every frame
##     forever. The world scan in `driver.nim` is the reconciler, at 2 Hz, not
##     the primary path.
##
## ## What this file still cannot do, stated rather than approximated
##
##  * **It is not on Unity's main thread, and that sentence has narrowed.**
##    `onUpdate` runs on the host's own attached thread. Reading managed fields
##    from it is fine; issuing movement and steering calls that end in Unity
##    APIs is the open question. What changed is the second half of what this
##    used to say: `invoke_main` no longer merely queues onto the host's
##    thread. The host detours a per-frame method and drains from inside it, so
##    `onMainThread` reaches Unity's thread on a build where one of its
##    candidates binds, and `call("aowlspt.host::main_thread")` says whether it
##    has actually fired. `client/coverprobe.nim` was the first thing in this
##    mod to use that, because a raycast has no other legal home; the driving
##    calls are the second, and that row is no longer open. See "Driving on
##    Unity's thread" at the foot of this file for the ring, and `core/sig.nim`
##    for the declared-signature gate every one of them now passes before it is
##    bound. What is still **not** claimed is that the calls then work: nothing
##    in this repo has ever executed one against BSG's client.
##  * **Cover points now have a source, and it is not in this file.**
##    `core/cover.nim` scores cover points and always could; what it lacked was
##    points, because producing one means a raycast and a raycast is a Unity
##    call. `client/coverprobe.nim` makes those calls from inside an
##    `onMainThread` job and `core/probe.nim` folds the answers back in, so
##    `CoverSet` fills and `inCoverStatus` leaves `csFarFromCover`. Two things
##    still have to be true for that to happen in a raid and both are asked
##    rather than assumed: `UnityEngine.Physics::Raycast` must resolve with the
##    signature this mod reads, and the host's per-frame drain must have
##    actually fired. Either one absent and the behaviour is exactly what it
##    was -- an empty set, and the ladder falling through to the rungs below.
##  * **Bleeds and fractures are not read.** They need walking the health
##    controller's effect collection, which is a generic instantiation with no
##    name `findClass` accepts and no instance in hand to bind from. `List<T>`
##    is reachable only because an *instance* of one turns up in hand; an
##    effect list does not, because reaching it is itself the generic call.
##  * **The squad is no longer a stub, and is not read either.** Enumerating
##    `BotsGroup` needs five guessed member names on an unseen class. What is
##    read is the group's *pointer*, as an identity, and `core/squad.nim`
##    partitions this mod's own bot table by it -- with faction and proximity
##    as the fallback when even that one getter refuses. See `README.md`.

import aowlspt
import aowlspt/game
import aowlspt/il2cpp
import aowlspt/fast
import ".." / core / vec
import ".." / core / types
import ".." / core / enemy
import ".." / core / hearing
import live
import coverprobe
import drivecalls
import mainthread

# The type surface used for the *capability probe only*. Resolved on first use,
# because a type resolved at load time is a false negative: the game has not
# loaded its assemblies when a mod starts.
var GameWorld = gameType("EFT.GameWorld")

type
  Capability* = enum
    ## What this client build actually supports, discovered rather than assumed.
    capNone            ## the game is not up
    capReadOnly        ## the world exists but the bot graph cannot be walked
    capFull            ## bots can be read and driven

var gCapability = capNone
var gAliveCount = 0
proc aliveCount*(): int = gAliveCount
  ## What step 7 counted off `GameWorld.AllAlivePlayersList@0x1c8` on the last
  ## pass. Handed to `levelOneVerdict` rather than re-read, so the probe and
  ## the verdict cannot disagree about how many players there were.
var gAnnounced = false
var gProbeNote = ""

# ---------------------------------------------------------------------------
# Breadcrumbs through the arming path
#
# MEASURED, from the archived crashing run `D:\Aowlspt\hostlogs\sain-crash.log`:
# `invoke_main now runs on Unity's main thread` at 0:00:08.032, the client dead
# by 0:00:08.141, and this mod logged NOTHING in between. It could not: the
# first line `probe` produces comes from `announce`, which runs AFTER every hop
# below, so "somewhere in the arming path" was the whole of what a crash could
# say and one more guess costs another launch. `mods/fov`'s `openRuntime` grew
# `step N/3` breadcrumbs for exactly this reason and they are what named its
# failing sub-step.
#
# FIRST PASS ONLY. `probe` is re-called on a two-second poll between raids; a
# trace that repeated forever would be a standing cost for an answer that only
# ever matters once. `gCrumbsDone` is set when a pass reaches the end.
var gCrumbsDone = false
var gProbePasses = 0

proc crumb(s: string) =
  if not gCrumbsDone:
    info "sain: arming " & s

proc capability*(): Capability = gCapability

proc probe*(): Capability =
  ## Ask the game two questions and classify the answers.
  ##
  ## The first is the host's: does `EFT.GameWorld` resolve at all? That is the
  ## cheap "is there a raid" test and it is the one thing worth asking every
  ## couple of seconds.
  ##
  ## The second is this mod's own: with the runtime bound directly, does
  ## `GameWorld.Instance` come back, and does its alive-players list have a
  ## length? Those two together are the whole of what the bot walk depends on.
  ## Anything past them degrades to a default rather than to nothing.
  # One pass is traced and one only. Between raids `probe` runs every two
  # seconds and returns at step 5 with a null world, so a trace gated on
  # "reached the end" would print six lines every two seconds for the whole
  # menu -- a standing cost for an answer already given.
  if gProbePasses > 0:
    gCrumbsDone = true
  inc gProbePasses
  crumb("step 1/7: asking the host whether EFT.GameWorld resolves")
  if not available(GameWorld):
    gCapability = capNone
    gProbeNote = "EFT.GameWorld does not resolve"
    crumb("step 1/7 answered no; the arming path stops here")
    return gCapability
  crumb("step 2/7: openLive -- binding GameAssembly.dll's C API directly")
  if not openLive():
    gCapability = capReadOnly
    gProbeNote = "GameAssembly.dll is not bound in this process, so the fast " &
                 "path is unavailable"
    crumb("step 2/7 refused; the arming path stops here")
    return gCapability
  crumb("step 3/7: bindAll -- resolving this mod's whole method table")
  bindAll()
  crumb("step 3/7 returned")
  # The cover sensor. This step USED to resolve two Unity statics by name and
  # was measured as the last line the mod ever logged before the client died
  # (fact #144 -- and that fact should be read knowing the host log loses about
  # six statements of tail on a hard death, so it names the last line LOGGED,
  # not necessarily the last EXECUTED).
  #
  # It no longer resolves anything. `bindProbe` now only BYTE-VERIFIES two
  # offline-resolved RVAs against the startup prologue snapshot: it reads code
  # pages, patches nothing, calls nothing into game code, and touches no export.
  # That is why it is still safe on this thread, whichever thread this is.
  #
  # The CALLS are a separate question and are answered elsewhere: `runSample`
  # is reached only from `onMainThread(coverJob)` (driver.nim) and `applyTo`
  # only from `onMainThread(driveJob)` or the explicitly-flagged host-thread
  # fallback. Verification here, execution on Unity's thread there.
  crumb("step 4/7: bindProbe -- byte-verifying the cover sensor RVAs (no " &
        "name resolved, no game code called)")
  bindProbe()
  crumb("step 4/7 returned")
  # STEP 5 NO LONGER CALLS ANYTHING. It used to call
  # `EFT.GameWorld::get_Instance`, which does not exist on this build, through
  # a by-name handle into unmapped memory -- MEASURED as the last thing this
  # mod ever did before the client died. The world is now borrowed from the
  # host's read-only export instead. See `client/live.nim`.
  crumb("step 5/7: borrowing the live GameWorld from the host export " &
        "(no call into game code)")
  let world = worldObject()
  crumb("step 5/7 returned " & (if world == nil: "null" else: "non-null") &
        " -- " & gwStateText())
  if world == nil:
    gCapability = capReadOnly
    # THREE ANSWERS, NOT TWO. `gwStateText` distinguishes "not in a raid" from
    # "nothing is armed to look", and flattening those is exactly the
    # can-only-say-yes failure CLAUDE.md 9b is about.
    gProbeNote = "no live GameWorld: " & gwStateText()
    return gCapability
  # STEP 6 IS A FIELD READ, not a call. `get_AllAlivePlayersList` does not
  # exist either (same 409-member dump); `AllAlivePlayersList` is an instance
  # field at a measured 0x1c8, read off the world the host validated.
  crumb("step 6/7: reading the measured field AllAlivePlayersList@0x1c8 off " &
        "the borrowed world (no call into game code)")
  let list = alivePlayers(world)
  crumb("step 6/7 returned " & (if list == nil: "null" else: "non-null"))
  if list == nil:
    gCapability = capReadOnly
    gProbeNote = "the alive-players list read back null at " &
                 "AllAlivePlayersList@0x1c8 off a world the host had " &
                 "validated -- that is a real answer and not a refusal, and " &
                 "it means this offset is not what it was measured to be"
    crumb("step 6/7 gave null; the arming path stops here")
    return gCapability

  # STEP 7 REFUSES, AND capFull IS NOT REACHED. This is the deliberate part.
  #
  # Everything past here -- the bot walk, every sensor, every driving call --
  # goes through `LazyCall`/`ensure`, which resolves members BY NAME.
  #
  # THE REASON WRITTEN HERE USED TO BE WRONG, and it was copied verbatim into
  # 24 setting descriptions, so it is corrected at the source rather than
  # patched at the leaves. It said `capFull` was refused because
  # `il2cpp_object_get_class` faults. It does not fault: it is literally
  # `mov rax,[rcx]; ret`, ungated and intact, which is WORSE -- a bad receiver
  # yields a plausible number in silence.
  #
  # The real reason, and it still fully justifies the refusal: `LazyCall`'s
  # binding goes through `il2cpp_class_from_name` /
  # `il2cpp_class_get_method_from_name`, which are among the 40 TOKEN-GATED
  # exports on this build. Called in the stock shape -- without the extra
  # 32-byte token argument -- they do not return NULL and do not abort. They
  # return a uniform random non-zero uint64 from a per-thread MT19937-64. So
  # the nil check passes, the handle is garbage, and the first dereference
  # kills the client with a log byte-identical to a healthy run. That is what
  # killed arming at `UnityEngine.Physics::Raycast`.
  #
  # WHY THAT MATTERS FOR ANYONE TRYING TO FIX THIS: the blocker is the BINDING
  # MECHANISM, not the operation. A bot walk built out of byte-verified static
  # RVAs and metadata field offsets bypasses the export ABI entirely and no
  # gate touches it -- which is exactly what `server/drive.nim` and the host's
  # `botnav` detour already are, and why per-role difficulty reaches bots
  # through THAT path while nothing in `core/decide.nim` does. Reviving this
  # driver means replacing `LazyCall` with an RVA table, not re-enabling
  # `capFull`.
  #
  # So `capFull` would not be a capability, it would be a licence to walk
  # straight back into the fault this whole pass removed.
  #
  # The mod therefore stays at `capReadOnly`: it boots, it says what it found
  # and what it cannot do, and it drives nothing. That is a mod declining
  # loudly, which CLAUDE.md 6 asks for, rather than a mod that kills the
  # client -- and it is honestly worse than the old behaviour looked, because
  # the old behaviour never worked at all.
  # STEP 7 NOW COUNTS THE LIST, without calling into game code. `listLen` reads
  # `_size` off the measured `List<Player>` layout (fact #226, MEASURED LIVE in
  # a 40-player raid): every hop VirtualQueried, `_size` clamped to the backing
  # array's `max_length`, no by-name binding. So the count sub-blocker is lifted
  # and this is an observable, self-validating fact (CLAUDE.md 9b): the note
  # reports the live count, which is falsifiable against the raid.
  #
  # capFull IS STILL NOT REACHED, and the reason is now precisely the SECOND
  # blocker, not the count: every sensor read and every driving call past the
  # count still goes through `LazyCall`/`ensure` -> `resolveOn` -> `findOn` ->
  # `findMethod`, which calls `il2cpp_class_get_method_from_name` DIRECTLY on the
  # runtime entry table (confirmed: `il2cpp.findMethod` invokes `rt.fns[...]`,
  # NOT the host gate). That export is TOKEN-GATED on this build: called in the
  # stock shape it returns a uniform random non-zero uint64, the nil check
  # passes, and the first dereference kills the client. Lifting capFull requires
  # replacing those by-name call sites with the byte-verified static-RVA table
  # (docs/SAIN_RVA.md) -- the ~6 drive setters AND the ~50 sensor getters -- not
  # re-enabling `capFull` over the fatal path. That conversion is not done here.
  let liveCount = listLen(list)
  gAliveCount = liveCount

  # STEP 7's REFUSAL IS NOW CONDITIONAL, and the condition is exactly the thing
  # the long comment above says would have to change.
  #
  # That comment ends "Reviving to capFull needs those call sites replaced with
  # the byte-verified RVA table, not the fatal path re-enabled." THE CALL SITES
  # HAVE BEEN REPLACED. `client/rvatable.nim` carries 27 static-RVA rows and 9
  # field rows; `live.ensure` takes the RVA path FIRST for any member carrying
  # an `rvaKey` and never reaches `il2cpp_object_get_class` for one; and every
  # member the table does not cover is a STATED refusal that is never retried
  # reflectively.
  #
  # So the honest reading is that the refusal was discharged by the RVA table
  # and then OUTLIVED it: the mod went on refusing capFull for a mechanism it
  # no longer uses, which made every downstream verdict -- reads, cover,
  # decisions, drives -- INCONCLUSIVE for a reason that had stopped being true.
  # That is CLAUDE.md 9b from the other side: not a check that cannot fail, but
  # a refusal that cannot lift.
  #
  # THE CONDITION IS THE DRIVE LEVEL, NOT THE FLAG, and deliberately so. At
  # level 0 nothing binds at all, so capFull would be a licence to walk members
  # that are all going to refuse. `sainRvaTable` false leaves the refusal below
  # EXACTLY as it was, so turning the table off is still the way back to the
  # previously shipped behaviour without a rebuild.
  if rvaTableOn() and rvaDriveLevel() >= RvaLevelReads:
    gCapability = capFull
    gProbeNote = "the world and the alive-players list were both reached " &
      "without calling into game code, and the list COUNTS: " & $liveCount &
      " alive players. capFull is GRANTED because the second blocker was " &
      "REMOVED rather than waived: every sensor read on the walk past this " &
      "point carries an rvaKey and binds either at a static RVA whose 16 " &
      "prologue bytes the host compares against its startup snapshot, or at a " &
      "fieldOffsets offset with a VirtualQuery per hop. No member reaches " &
      "il2cpp_class_get_method_from_name. Members the table does not cover are " &
      "stated refusals and are NOT retried by name. Drive level is " &
      rvaLevelName(rvaDriveLevel()) & ", which bounds how much of the table " &
      "may bind. THIS IS NOT A CLAIM THAT ANY BOT WAS READ -- it is a claim " &
      "that the walk is allowed to try. The per-raid LEVEL census and the " &
      "verdicts are the instrument for whether it worked"
    crumb("step 7/7: counted the alive-players list = " & $liveCount &
          "; capFull GRANTED (RVA table on at " &
          rvaLevelName(rvaDriveLevel()) & ")")
    crumb("step 7/7 granted; the arming path is complete and this trace stops")
    gCrumbsDone = true
    return gCapability

  crumb("step 7/7: counted the alive-players list = " & $liveCount &
        " (measured layout, no game call); capFull still refused -- by-name " &
        "sensor/drive binding")
  gCapability = capReadOnly
  gProbeNote = "the world and the alive-players list were both reached " &
               "without calling into game code, and the list now COUNTS: " &
               $liveCount & " alive players (fact #226 measured layout, every " &
               "hop VirtualQueried, no by-name binding). What still refuses " &
               "capFull is the SECOND blocker: every sensor read and driving " &
               "call past the count binds BY NAME through " &
               "il2cpp_class_get_method_from_name -- called directly on the " &
               "runtime entry table (il2cpp.findMethod), a TOKEN-GATED export " &
               "that returns a plausible RANDOM handle instead of failing, so " &
               "the nil check passes and the first dereference kills the " &
               "client. Reviving to capFull needs those call sites replaced " &
               "with the byte-verified RVA table (docs/SAIN_RVA.md), not the " &
               "fatal path re-enabled. Meanwhile difficulty and per-role " &
               "difficulty do reach bots, over server/drive.nim's botnav " &
               "path, which uses byte-verified RVAs and no name lookup. THE WAY PAST " &
               "THIS on this build is sainRvaTable = true at " &
               "sainRvaTableDriveLevel >= 1; it is currently " &
               (if rvaTableOn(): "ON at " & rvaLevelName(rvaDriveLevel())
                else: "OFF")
  crumb("step 7/7 refused; the arming path is complete and this trace stops")
  gCrumbsDone = true
  result = gCapability

proc announce*() =
  ## Say what this build can do, once, in terms someone reading a log can act
  ## on. A mod that quietly does half its job is worse than one that says which
  ## half.
  if gAnnounced:
    return
  gAnnounced = true
  case gCapability
  of capNone:
    info "sain: the game world is not up yet"
  of capReadOnly:
    warn "sain: the bot object graph cannot be walked -- " & gProbeNote &
         ". The decision core is running in observer mode; nothing is being " &
         "driven."
  of capFull:
    success "sain: driving bots (" & gProbeNote & ")"
  report()
  # Two lines, always, and separate. The first is whether the engine will
  # answer a raycast at all; the second is whether this mod is allowed to ask
  # from the thread it is on. Either one absent means no cover points, and a
  # log that ran them together could not say which.
  info "sain: " & probeState()
  # Asked here rather than read here: `announce` runs on the first tick the
  # world resolves, which is before the driver's own two-second poll has ever
  # fired, and a report that said "not asked yet" would be reporting this
  # function's ordering rather than the host's answer.
  discard refreshMainThread(nowMs())
  info "sain: main thread -- " & mainThreadNote()

proc capable*(): bool = gCapability == capFull

# ---------------------------------------------------------------------------
# A bot
# ---------------------------------------------------------------------------

type
  BotHandle* = object
    ## A bot, as this bridge addresses it.
    ##
    ## `id` is the profile id and is the key everything else uses: it survives a
    ## handle being released and it is what the decision core keys its per-bot
    ## state on. `gcPlayer` is this mod's own IL2CPP GC handle on the bot's
    ## `Player`, taken at attach and freed at detach.
    ##
    ## It is *not* a host `Handle`, and the distinction outlived the reason for
    ## it. It used to be that nothing could turn a host handle into the raw
    ## pointer the fast path needs; ABI revision 3's `pointerOf` can, and the
    ## spawn hook uses it. What a host handle still cannot do is *last*: the
    ## host reclaims it when the handler returns. So the pointer is taken
    ## inside the handler and immediately turned into one of these -- an IL2CPP
    ## GC handle this mod owns, which is the only legal way to keep an object
    ## across frames. See the note at the top of `live.nim`.
    id*: string
    role*: BotRole
    gcPlayer*: uint32

  BotLive* = object
    ## One tick's pointers for one bot. Never stored: the collector moves
    ## objects, so these are good for this frame and no longer.
    ok*: bool
    player*: Il2CppPtr
    owner*: Il2CppPtr

func noBot*(): BotLive =
  BotLive(ok: false, player: cast[Il2CppPtr](0), owner: cast[Il2CppPtr](0))

func roleFromSpawnType*(name: string): BotRole =
  ## BSG's `WildSpawnType` has three dozen members; SAIN keys per-bot settings
  ## off all of them. The decision core reads a coarse grouping, so the mapping
  ## happens here, once, at spawn.
  if name.len == 0: return brScav
  case name
  of "pmcBEAR", "pmcUSEC", "pmcBot", "sptUsec", "sptBear": brPmc
  of "pmcBot_raider", "exUsec", "pmcBot_rogue": brRaider
  of "assault", "assaultGroup", "cursedAssault", "marksman": brScav
  of "playerScav": brPlayerScav
  of "followerBully", "followerKojaniy", "followerGluharAssault",
     "followerGluharSecurity", "followerGluharScout",
     "followerGluharSnipe", "followerSanitar", "followerTagilla",
     "followerBirdEye", "followerBigPipe": brFollower
  of "bossKnight", "followerBirdeye", "followerBigpipe": brGoon
  of "infectedAssault", "infectedPmc", "infectedCivil", "infectedLaborant",
     "infectedTagilla": brZombie
  else:
    # Everything left that starts with "boss" is a boss; an unknown spawn type
    # is a scav, which is the safe default because scav settings are the least
    # aggressive.
    if name.len >= 4 and name[0] == 'b' and name[1] == 'o' and
       name[2] == 's' and name[3] == 's': brBoss
    else: brScav

proc attach*(b: var BotHandle; player: Il2CppPtr) =
  ## Take the one handle this bot costs. Idempotent: re-attaching the same bot
  ## would leak the first handle, and a raid re-attaches on every scan.
  if b.gcPlayer != 0'u32:
    return
  b.gcPlayer = hold(player)

proc detach*(b: var BotHandle) =
  ## Give the handle back. Called when the bot dies or the raid ends; a handle
  ## kept past that pins a corpse for the session.
  if b.gcPlayer == 0'u32:
    return
  drop(b.gcPlayer)
  b.gcPlayer = 0'u32

proc liveOf*(b: BotHandle): BotLive =
  ## This frame's pointers.
  ##
  ## One `gc_handle_get_target` and two bound property calls. The `BotOwner` is
  ## re-derived rather than held for the reason in the module comment: two more
  ## handles would cost two more handle lookups per tick and pin an object the
  ## game may have replaced.
  result = noBot()
  if b.gcPlayer == 0'u32:
    return
  let p = target(b.gcPlayer)
  if p == nil:
    return
  result.player = p
  let ai = callObj(gB.pAIData, p)
  if ai != nil:
    result.owner = callObj(gB.aiBotOwner, ai)
  result.ok = true

proc profileIdOf*(player: Il2CppPtr): string =
  ## The bot's key. A managed string, copied out once at attach and never read
  ## again -- reading it per tick would put a UTF-16 to UTF-8 conversion on the
  ## hot path for a value that cannot change.
  result = ""
  if player == nil:
    return
  result = readManagedString(callObj(gB.pProfileId, player))

proc isAI*(player: Il2CppPtr): bool =
  ## Whether this is a bot rather than the human. One bound call returning a
  ## bool: the cheapest shape the fast path has.
  callBoolOn(gB.pIsAI, player, false)

proc isAlive*(player: Il2CppPtr): bool =
  ## Death detection, **the fallback**.
  ##
  ## This used to be the only way. The natural hook is `Player::OnDead`, but
  ## `hookArgs` reported a method's *declared* arguments and not the instance
  ## it was called on, so a death hook fired knowing that a player died and not
  ## which one. The host computed `this` and did not surface it, so one bound
  ## bool read per bot per decision was the honest answer: it could not be
  ## wrong, and it cost two bound calls -- `get_HealthController` and this --
  ## for a fact that changes once in a bot's life.
  ##
  ## ABI revision 3's `pointerOf`, reached through `game.thisPointer`, surfaces
  ## it. `sain.installHooks` now detours `OnDead` and `driver.setDeathHooked`
  ## turns this off. It stays for the case that is still real: a host older
  ## than revision 3, a host with no managed heap, or a build where none of the
  ## death-method names patches. The mod's own self-test measures what it costs
  ## when it is on, so the trade is a number rather than an opinion.
  let hc = callObj(gB.pHealth, player)
  if hc == nil:
    return true
  callBoolOn(gB.hcAlive, hc, true)

# ---------------------------------------------------------------------------
# Reading a bot
# ---------------------------------------------------------------------------

const
  BodyPartCommon = 7'i32
    ## `EBodyPart.Common` -- the aggregate SAIN reads for "how hurt is this
    ## bot". The ordinal is the pre-1.0 one and is the single most likely
    ## number in this file to be wrong on a post-1.0 client; getting it wrong
    ## reads a different limb's health rather than garbage, and the binding
    ## report will not catch it. If bot health behaviour looks off, check this
    ## first.

proc readHealth(l: BotLive): float =
  ## Health as a fraction.
  ##
  ## **The one read left on the reflective path**, and left there on purpose.
  ##
  ## `GetBodyPartHealth` takes an enum and returns a value struct, so its shaped
  ## form would be three slots -- hidden return pointer, `this`, the enum -- and
  ## `live.tryShaped` could express it. What it could not do is *read* the
  ## result: with the callee writing into a caller buffer there is no boxed
  ## object, so `Current` and `Maximum` would have to be pulled out by offset,
  ## and a field offset inside a value type is the one number in this area that
  ## nothing here can check. `il2cpp_runtime_invoke` boxes the result instead
  ## and `il2cpp_field_get_value` reads the two floats *by name*, which needs no
  ## assumption at all.
  ##
  ## The cost is one managed allocation and one reflective call per bot per
  ## decision -- roughly a third of what reading a bot costs now that the three
  ## Vector3 reads are shaped. Worth revisiting if a profile says so; not worth
  ## a second unverifiable layout assumption before then.
  result = 1.0
  if l.player == nil:
    return
  let hc = callObj(gB.pHealth, l.player)
  if hc == nil:
    return
  let boxed = callIntArg(gB.hcBodyPart, hc, BodyPartCommon)
  if boxed == nil:
    return
  let maxv = readStructFloat(gB.vsMaximum, boxed, 0.0)
  if maxv <= 0.0:
    return
  result = clampf(readStructFloat(gB.vsCurrent, boxed, maxv) / maxv, 0.0, 1.0)

proc readStamina(l: BotLive): float =
  result = 1.0
  if l.player == nil:
    return
  let ph = callObj(gB.pPhysical, l.player)
  if ph == nil:
    return
  let st = callObj(gB.phStamina, ph)
  if st == nil:
    return
  result = clampf(callFloatOn(gB.stNormal, st, 1.0), 0.0, 1.0)

# ---------------------------------------------------------------------------
# The per-sensor verdict
# ---------------------------------------------------------------------------
#
# CLAUDE.md 9b, applied to this change specifically. `report()` and `rvaReport()`
# both say what BOUND. Neither can say whether anything was READ, and "the row
# bound" is precisely the self-comparison that rule forbids: it asserts our own
# write. So this walks each chain against a live bot and states, per sensor,
# what came back.
#
# THREE outcomes, never two:
#
#   PASS          a value arrived and is plausible for its type -- a non-null
#                 object, a stamina fraction inside [0,1].
#   FAIL hop N    the chain broke, and WHICH hop broke is named. A break at
#                 hop 1 is a receiver problem; at the last hop it is an offset
#                 problem. Collapsing them would lose the only diagnostic here.
#   INCONCLUSIVE  nothing was looked at -- the table is off, there is no bot,
#                 or the receiver could not be confirmed. "I could not look" is
#                 NOT a pass.
#
# What would make this FAIL: any hop returning null or refusing its guard. What
# would make it INCONCLUSIVE: no live bot. It runs ONCE per session, off the
# per-frame path, and allocates nothing managed.

var gVerdictsDone = false

proc verdict(sensor, outcome, detail: string) =
  if outcome == "PASS":
    info "sain: SENSOR PASS         " & sensor & " -- " & detail
  elif outcome == "INCONCLUSIVE":
    warn "sain: SENSOR INCONCLUSIVE " & sensor & " -- " & detail
  else:
    warn "sain: SENSOR FAIL         " & sensor & " -- " & detail

proc sensorVerdicts*(l: BotLive) =
  ## Run the newly-wired chains against one live bot and report each one.
  if gVerdictsDone:
    return
  if not rvaTableOn():
    gVerdictsDone = true
    warn "sain: SENSOR verdicts INCONCLUSIVE for every sensor -- sainRvaTable " &
         "is OFF (its default), so no chain was walked. This is not a pass."
    return
  if rvaDriveLevel() < RvaLevelReads:
    gVerdictsDone = true
    warn "sain: SENSOR verdicts INCONCLUSIVE for every sensor -- " &
         "sainRvaTable is on but sainRvaTableDriveLevel is " &
         rvaLevelName(rvaDriveLevel()) & ", so no member bound and no chain " &
         "was walked. This is not a pass, and it is a DIFFERENT state from " &
         "the flag being off: the table loaded and reported itself."
    return
  if not l.ok or l.player == nil:
    return                      # no bot yet; try again next tick, stay silent
  gVerdictsDone = true
  info "sain: per-sensor verdicts, one live bot, walked once. PASS means a " &
       "value came back and is plausible FOR ITS TYPE -- it does not mean the " &
       "value is correct, which nothing here can establish."

  # --- pPhysical -> phStamina -> stNormal. Three hops, and the verdict names
  # the one that broke.
  let ph = callObj(gB.pPhysical, l.player)
  if ph == nil:
    verdict("pPhysical", "FAIL",
            "hop 1 of 3 (EFT.Player.Physical@0x9D8) returned null or refused " &
            "its guard. Either the receiver is not an EFT.Player, or the " &
            "offset is stale for the installed GameAssembly.dll.")
    verdict("phStamina", "INCONCLUSIVE", "not reached: pPhysical failed at hop 1")
    verdict("mcSprint", "INCONCLUSIVE", "not reached: pPhysical failed at hop 1")
  else:
    verdict("pPhysical", "PASS",
            "hop 1 of 3 returned a readable PhysicalBase. This member was " &
            "ABSENT AS A METHOD on this build and is now read as a field.")
    let st = callObj(gB.phStamina, ph)
    if st == nil:
      verdict("phStamina", "FAIL",
              "hop 2 of 3 (PhysicalBase.Stamina@0x68) returned null off a " &
              "PhysicalBase that hop 1 produced, so the receiver is right and " &
              "the OFFSET is the suspect.")
    else:
      let v = callFloatOn(gB.stNormal, st, -1.0)
      if v < 0.0 or v > 1.0:
        verdict("phStamina", "FAIL",
                "hop 3 of 3: the bound Stamina::get_NormalValue @0x1CB0720 " &
                "answered " & $v & ", which is outside [0,1] and is therefore " &
                "not a stamina fraction. Hops 1 and 2 succeeded, so this is " &
                "the CALL, not the walk -- most likely the receiver at 0x68 " &
                "is a sibling (HandsStamina@0x70, Oxygen@0x78) rather than " &
                "Stamina, which would read plausibly and answer wrongly.")
      else:
        verdict("phStamina", "PASS",
                "stamina read END TO END for the first time: normalised " &
                "value " & $v & ", inside [0,1]. Three hops, two of them " &
                "fields that were refusals until now.")
    # `mcSprint` reads off the SAME PhysicalBase, so a receiver failure here
    # cannot be confused with an offset failure.
    let sp = callBoolOn(gB.mcSprint, ph, false)
    let sp2 = callBoolOn(gB.mcSprint, ph, true)
    if sp != sp2:
      verdict("mcSprint", "FAIL",
              "PhysicalBase._sprinting@0xD9 answered with the CALLER'S " &
              "DEFAULT both times (false then true), which means the read was " &
              "refused at its guard and no byte was ever examined. A bool " &
              "sensor that returns the default is indistinguishable from a " &
              "bot that is not sprinting -- asking twice with opposite " &
              "defaults is what tells them apart.")
    else:
      verdict("mcSprint", "PASS",
              "PhysicalBase._sprinting@0xD9 read a real byte: " & $sp &
              ", identical under both defaults, so it is the object's value " &
              "and not ours.")

  if l.owner == nil:
    verdict("boMemory", "INCONCLUSIVE", "no BotOwner on this bot this tick")
    verdict("memUnderFire", "INCONCLUSIVE", "not reached: no BotOwner")
    verdict("memGoalEnemy", "INCONCLUSIVE", "not reached: no BotOwner")
    verdict("wmReady", "INCONCLUSIVE", "not reached: no BotOwner")
    verdict("medFirstAid", "INCONCLUSIVE", "not reached: no BotOwner")
    verdict("medStims", "INCONCLUSIVE", "not reached: no BotOwner")
    verdict("medSurgery", "INCONCLUSIVE", "not reached: no BotOwner")
    return

  # --- boMemory -> { memUnderFire (a bound RVA call), memGoalEnemy }
  let mem = callObj(gB.boMemory, l.owner)
  if mem == nil:
    verdict("boMemory", "FAIL",
            "hop 1 (EFT.BotOwner.Memory@0x60) returned null or refused. The " &
            "NAME get_Memory was refused as a profiler counter; this is the " &
            "field route and it did not answer either.")
    verdict("memUnderFire", "INCONCLUSIVE", "not reached: boMemory failed")
    verdict("memGoalEnemy", "INCONCLUSIVE", "not reached: boMemory failed")
  else:
    verdict("boMemory", "PASS", "hop 1 returned a readable BotMemory.")
    let uf = callBoolOn(gB.memUnderFire, mem, false)
    let uf2 = callBoolOn(gB.memUnderFire, mem, true)
    if uf != uf2:
      verdict("memUnderFire", "FAIL",
              "the ALREADY-BOUND BotMemory::get_IsUnderFire @0x24DEEC0 " &
              "returned the caller's default under both defaults, so it was " &
              "never called. The row has been bound and unreachable; this " &
              "says it is still unreachable.")
    else:
      verdict("memUnderFire", "PASS",
              "a row that has been BOUND AND UNREACHABLE since the table " &
              "existed now has a receiver: IsUnderFire = " & $uf &
              ", stable under both defaults.")
    let goal = callObj(gB.memGoalEnemy, mem)
    if goal == nil:
      # Genuinely ambiguous, and saying so is the whole point: a bot with no
      # enemy has a null `_goalEnemy` and that is CORRECT.
      verdict("memGoalEnemy", "INCONCLUSIVE",
              "BotMemory._goalEnemy@0x60 read null. A bot with no current " &
              "enemy has a null goal enemy, so this is INDISTINGUISHABLE from " &
              "a working read on a peaceful bot and is NOT reported as a " &
              "failure. Re-run it on a bot in contact to settle it.")
    else:
      verdict("memGoalEnemy", "PASS",
              "BotMemory._goalEnemy@0x60 returned a readable EnemyInfo, which " &
              "is the receiver the bound enPerson/enPosition rows want.")

  # --- boWeapon (bound RVA) -> wmReady (field)
  let wm = callObj(gB.boWeapon, l.owner)
  if wm == nil:
    verdict("wmReady", "INCONCLUSIVE",
            "not reached: the bound BotOwner::get_WeaponManager @0x80F040 " &
            "returned null, so no receiver arrived.")
  else:
    let r1 = callBoolOn(gB.wmReady, wm, false)
    let r2 = callBoolOn(gB.wmReady, wm, true)
    if r1 != r2:
      verdict("wmReady", "FAIL",
              "BotWeaponManager.<IsReady>@0x80 returned the caller's default " &
              "under both defaults -- the read was refused at its guard.")
    else:
      verdict("wmReady", "PASS",
              "BotWeaponManager.<IsReady>@0x80 read a real byte: " & $r1 &
              ". Replaces the AMBIGUOUS get_IsReady with no name to disambiguate.")

  # --- boMedecine (bound, UNIQUE RVA) -> the three medical components
  let med = callObj(gB.boMedecine, l.owner)
  if med == nil:
    verdict("medFirstAid", "INCONCLUSIVE", "not reached: get_Medecine null")
    verdict("medStims", "INCONCLUSIVE", "not reached: get_Medecine null")
    verdict("medSurgery", "INCONCLUSIVE", "not reached: get_Medecine null")
    verdict("faShall", "INCONCLUSIVE", "not reached: get_Medecine null")
    verdict("surgShall", "INCONCLUSIVE", "not reached: get_Medecine null")
  else:
    let fa = callObj(gB.medFirstAid, med)
    if fa == nil:
      verdict("medFirstAid", "FAIL",
              "BotMedecine.FirstAid@0x18 read null off a BotMedecine the " &
              "UNIQUE get_Medecine produced -- receiver right, offset suspect.")
      verdict("faShall", "INCONCLUSIVE", "not reached: medFirstAid was null")
    else:
      verdict("medFirstAid", "PASS",
              "BotMedecine.FirstAid@0x18 returned a readable BotFirstAid; " &
              "canHeal = " & $callBoolOn(gB.faHave, fa, false))
      # Two DIFFERENT defaults on purpose. `faShall` is read with a default of
      # TRUE at the call site, because there it is ANDed with faHave and a
      # refused binding must not turn a false into a true. Here it is read
      # with FALSE, because this line is asking "did the call come back" and a
      # default that matches the interesting answer would make the verdict
      # unfalsifiable. Same row, two questions, and they want opposite
      # defaults -- which is worth the four extra words.
      verdict("faShall", "PASS",
              "BotFirstAid::ShallStartUse @0x1A203F0 (arity 0, bool, UNIQUE, " &
              "non-virtual) called on the BotFirstAid the field row above " &
              "produced: " & $callBoolOn(gB.faShall, fa, false) &
              ". This is the game's own 'would I start using this now', which " &
              "is a stricter question than faHave's 'is there an item'. It " &
              "sits beside the PERMANENTLY REFUSED drive call " &
              "TryApplyToCurrentPart @0x1A20740 -- see rvatable.nim for the " &
              "disassembly that refused it.")
    let stim = callObj(gB.medStims, med)
    if stim == nil:
      verdict("medStims", "FAIL",
              "BotMedecine.Stimulators@0x20 read null; receiver right, " &
              "offset suspect.")
    else:
      verdict("medStims", "PASS",
              "BotMedecine.Stimulators@0x20 returned a readable " &
              "BotStimulators. NOTE: canUseStims stays FALSE regardless -- " &
              "stimHave is still refused because whether BotStimulators " &
              "derives from BotAbstractMedsToPart is UNMEASURED. Reaching the " &
              "component is not reading it.")
    let surg = callObj(gB.medSurgery, med)
    if surg == nil:
      verdict("medSurgery", "FAIL",
              "BotMedecine.SurgicalKit@0x28 read null; receiver right, " &
              "offset suspect.")
      verdict("surgShall", "INCONCLUSIVE", "not reached: medSurgery was null")
    else:
      verdict("medSurgery", "PASS",
              "BotMedecine.SurgicalKit@0x28 returned a readable " &
              "BotSurgicalKit, which is the receiver the bound " &
              "BotSurgicalKit::get_HaveWork @0x1A24F20 wants; canDoSurgery = " &
              $callBoolOn(gB.surgHave, surg, false))
      verdict("surgShall", "PASS",
              "BotSurgicalKit::ShallStartUse @0x1A24F40 (arity 0, bool, " &
              "UNIQUE, non-virtual) called on that same BotSurgicalKit: " &
              $callBoolOn(gB.surgShall, surg, false) &
              ". The safe READ that sits beside the PERMANENTLY REFUSED " &
              "drive call ApplyToCurrentPart @0x1A252F0.")

  # --- and the ones that stayed refused, said out loud here too, so a reader
  # of the verdict block is not left to infer their absence.
  verdict("wGrenades", "INCONCLUSIVE",
          "REFUSED BY DESIGN, on receiver grounds: the field exists at 0x58 " &
          "on BotWeaponManager, but `grenadeList` passes the GAMEWORLD. A " &
          "foreign field read answers rather than faults, so it is not taken.")
  # --- The aim route, walked here as two hops and DELIBERATELY NOT verdicted
  # as a pass on the strength of the walk alone.
  #
  # Both hops returning a pointer proves the walk; it does not prove the
  # SENSOR, because the sensor is the postfix and the postfix is on an address
  # this walk never touches. Reporting PASS here for "two pointers came back"
  # would be the same shape of check that made the old hook look armed for its
  # whole life. So the verdict below tops out at "the walk works", and names
  # the number that settles the rest.
  if l.owner == nil:
    # "I could not look" is INCONCLUSIVE, never FAIL. Without this the two
    # hops below would both read null off a null receiver and be reported as
    # broken rows, which is a confidently wrong diagnosis of a correct table.
    verdict("boAiming", "INCONCLUSIVE", "not walked: no BotOwner on this bot")
    verdict("amCurrent", "INCONCLUSIVE", "not reached: no BotOwner")
  elif rvaDriveLevel() < RvaLevelAim:
    verdict("boAiming", "INCONCLUSIVE",
            "not walked: sainRvaTableDriveLevel is " &
            rvaLevelName(rvaDriveLevel()) & " and the aim route needs " &
            rvaLevelName(RvaLevelAim) & ".")
    verdict("amCurrent", "INCONCLUSIVE", "not reached: same level refusal.")
  else:
    let am = callObj(gB.boAiming, l.owner)
    if am == nil:
      verdict("boAiming", "FAIL",
              "hop 1 of 2 (EFT.BotOwner::get_AimingManager @0x80E9B0, UNIQUE) " &
              "returned null or refused its guard off the same BotOwner the " &
              "five bound get_* rows are called on.")
      verdict("amCurrent", "INCONCLUSIVE", "not reached: hop 1 failed.")
    else:
      verdict("boAiming", "PASS",
              "hop 1 of 2 returned a readable AimingManager. Used as an " &
              "identity only; nothing is called on it but hop 2.")
      let ad = callObj(gB.amCurrent, am)
      if ad == nil:
        verdict("amCurrent", "FAIL",
                "hop 2 of 2 (AimingManager::get_CurrentAiming @0x23D5B60, " &
                "UNIQUE) returned null off an AimingManager hop 1 produced. " &
                "A bot with no current aiming type reads this way too, so a " &
                "single null here is not proof the row is wrong.")
      else:
        verdict("amCurrent", "INCONCLUSIVE",
                "hop 2 of 2 returned a readable IBotAiming, so THE WALK " &
                "WORKS -- and that is not the same claim as the sensor " &
                "working, which is why this is not a PASS. The pointer is " &
                "only useful if the postfix on Aiming::get_IsReady @0x1AD48C0 " &
                "deposits readings under this SAME address. The falsifiable " &
                "statement is the driver status line's aim triple: `fired` > " &
                "0 says the postfix is on a live address, `matched` > 0 says " &
                "this walk keys on the same object it fires with. Either at " &
                "zero in a raid with bots is a FAIL that this one-shot walk " &
                "cannot see.")
  verdict("hcBodyPart", "INCONCLUSIVE",
          "REFUSED PERMANENTLY, on stronger grounds than the arity it used to " &
          "cite. EFT.Player._healthController@0xA20 is declared as the " &
          "INTERFACE IHealthController; the implementation a spawned bot most " &
          "likely has, ActiveHealthController, inherits BaseHealthController" &
          "`1::GetBodyPartHealth, whose only two bodies (0x3BCC200, 0x3BD24E0) " &
          "are SHARED GENERICS and so need a non-NULL MethodInfo* the RVA " &
          "path has none of. Nothing on this build can ask a live object " &
          "which implementation it is. CONSEQUENCE: readHealth returns 1.0, " &
          "so every bot is treated as at full health.")

proc readSelf*(b: BotHandle; l: BotLive): SelfView =
  ## One pass of reads into a plain struct.
  ##
  ## Every default below is the value that makes the decision core behave as
  ## though the thing it could not read is not a problem: full health, a full
  ## magazine, a ready weapon, no suppression. That direction is deliberate. A
  ## bot whose magazine count cannot be read should not spend the raid
  ## reloading.
  result = SelfView(
    healthNormalized: 1.0, energy: 1.0, hydration: 1.0, stamina: 1.0,
    hasHeavyBleed: false, hasLightBleed: false, hasFracture: false,
    canHeal: false, canUseStims: false, canDoSurgery: false,
    ammoInMagazine: 30, magazineSize: 30, hasAmmoToReload: false,
    weaponReady: true, inCoverStatus: csFarFromCover, coverPointDistance: 99.0,
    coverPosition: zeroVec(), hasCoverPoint: false,
    suppressionLevel: 0.0, isSprinting: false, position: zeroVec(),
    lookDirection: vec3(1.0, 0.0, 0.0), velocity: zeroVec(),
    timeSinceDamaged: 9999.0, recentDamage: 0.0)
  if not l.ok:
    return

  # Once per session, on the first bot that is actually live -- not at load,
  # because at load there is no receiver and every verdict would be
  # INCONCLUSIVE, which is a report that cannot fail.
  sensorVerdicts(l)

  # --- position and facing. Two shaped fast calls: the hidden return pointer
  # is a stack buffer in `live.readVec`, so these allocate nothing at all and
  # cost about what a bound call costs. They were the two most expensive reads
  # on this path when they went through `il2cpp_runtime_invoke`, which boxed a
  # Vector3 per read.
  result.position = readVec(gB.pPosition, l.player)
  result.lookDirection = readVec(gB.pLookDir, l.player)

  # --- condition
  result.healthNormalized = readHealth(l)
  result.stamina = readStamina(l)

  # Sprint state comes off the PHYSICAL, not off the MovementContext.
  #
  # `mcSprint` used to be `MovementContext::get_IsSprintEnabled`, which the RVA
  # table refuses -- the name is ambiguous across owners and nothing offline
  # picks the right one. It is now `PhysicalBase._sprinting@0xD9`, a field, and
  # a field offset is only meaningful on the type it was measured for. So the
  # receiver had to move with it: `pPhysical` yields the PhysicalBase, and that
  # is what is read. Passing the MovementContext here would still be readable,
  # would not fault, and would answer with whatever it keeps at 0xD9.
  let ph = callObj(gB.pPhysical, l.player)
  if ph != nil:
    result.isSprinting = callBoolOn(gB.mcSprint, ph, false)

  if l.owner == nil:
    return

  # --- suppression. `IsUnderFire` is a bool rather than a level, and mapping it
  # straight onto 0 and 1 -- which is what this used to do -- made both
  # thresholds in `settings.nim` meaningless: a bot was never merely
  # suppressed, only pinned, and it un-pinned on the frame the flag cleared.
  #
  # The bool is carried through raw here and `core/suppress.nim` integrates it
  # over time in the driver, along with the health delta. The level in this
  # struct is filled in by the driver after that pass, which is why it is left
  # at zero rather than set from the flag.
  let mem = callObj(gB.boMemory, l.owner)
  if mem != nil:
    result.suppressionLevel = (if callBoolOn(gB.memUnderFire, mem, false):
                                 1.0 else: 0.0)

  # --- weapon
  let wm = callObj(gB.boWeapon, l.owner)
  if wm != nil:
    result.hasAmmoToReload = callBoolOn(gB.wmHaveBullets, wm, false)
    result.weaponReady = callBoolOn(gB.wmReady, wm, true)
    let rl = callObj(gB.wmReload, wm)
    if rl != nil:
      let n = callIntOn(gB.rlBullets, rl, -1)
      let m = callIntOn(gB.rlMaxBullets, rl, -1)
      if n >= 0 and m > 0:
        result.ammoInMagazine = n
        result.magazineSize = m

  # --- what the bot could do to itself
  let med = callObj(gB.boMedecine, l.owner)
  if med != nil:
    # TWO reads per component, ANDed, and the second is the stricter one.
    #
    # `get_HaveSmth2Use` / `get_HaveWork` answer "is there an item" --
    # inventory, not intent. `ShallStartUse()` is the game's OWN answer to
    # "would this component start using itself right now", so it folds in the
    # cooldowns, the in-progress checks and the part selection that the mod
    # would otherwise be re-deriving badly. Both are arity-0 bools at UNIQUE
    # non-virtual RVAs and neither makes the bot do anything.
    #
    # ANDed rather than substituted: a refused `faShall` binding returns the
    # default `true`, which leaves the pair reading exactly as `faHave` alone
    # did. So the strictly-worse direction is the one a failure falls into,
    # and adding the read cannot turn a false into a true.
    let fa = callObj(gB.medFirstAid, med)
    if fa != nil:
      result.canHeal = callBoolOn(gB.faHave, fa, false) and
                       callBoolOn(gB.faShall, fa, true)
    let stim = callObj(gB.medStims, med)
    if stim != nil:
      result.canUseStims = callBoolOn(gB.stimHave, stim, false)
    let surg = callObj(gB.medSurgery, med)
    if surg != nil:
      result.canDoSurgery = callBoolOn(gB.surgHave, surg, false) and
                            callBoolOn(gB.surgShall, surg, true)

  # `hasHeavyBleed` / `hasLightBleed` / `hasFracture` stay false: reading them
  # means walking the health controller's effect collection, which is a generic
  # instantiation with no name `findClass` accepts and no instance in hand to
  # bind from. Stated rather than approximated -- guessing "bleeding" from a
  # falling health value would make the first-aid ladder fire on the wrong
  # cause.

proc observeEnemy*(b: BotHandle; l: BotLive; now: float): Observation =
  ## The bot's current goal enemy, as one `Observation` for `core/enemy`.
  ##
  ## The game has already done the expensive half -- the visibility raycast and
  ## the enemy selection -- so this reads its answer rather than repeating it.
  ## That is the sensing/logic split `docs/IL2CPP.md` recommends profiling
  ## before rewriting: the raycast is in the engine and costs what it costs.
  ##
  ## **The profile id is not read at all any more.** It used to be, per tick,
  ## and the comment here used to say what the fix would be if it ever showed
  ## up in a profile: key on the person pointer instead. That is what this now
  ## does -- and once the key is a pointer, the string has no remaining reader,
  ## so it is gone rather than merely cached. That removes the last managed
  ## allocation from the per-decision path.
  result = Observation(key: 0'u64, alive: false, isPlayer: false,
                       position: zeroVec(), sawThisTick: false,
                       heardThisTick: false, firedAtUsThisTick: false,
                       lookingAtUsThisTick: false, pathDistance: -1.0,
                       heard: nothingHeard())
  if not l.ok or l.owner == nil:
    return
  let mem = callObj(gB.boMemory, l.owner)
  if mem == nil:
    return
  let goal = callObj(gB.memGoalEnemy, mem)
  if goal == nil:
    return
  let person = callObj(gB.enPerson, goal)
  if person == nil:
    return
  result.key = cast[uint64](person)
  result.alive = true
  result.isPlayer = not callBoolOn(gB.pIsAI, person, true)
  result.position = readVec(gB.enPosition, goal)
  result.sawThisTick = callBoolOn(gB.enVisible, goal, false)
  # `firedAtUsThisTick` and `lookingAtUsThisTick` still have no direct read.
  # `heardThisTick` does now, but not from here: it is derived in the driver
  # from the enemy's own motion through `core/hearing`, because only the driver
  # holds the previous position to difference against.

proc groupKeyOf*(l: BotLive): uint64 =
  ## `BotOwner.BotsGroup` as an identity, never dereferenced.
  ##
  ## Zero means the binding refused, which `core/squad.nim` reads as "partition
  ## by faction and proximity instead". The pointer is not held across frames
  ## and does not need to be: it is compared against other bots' pointers read
  ## on the same tick, and a collector that moved the group would move every
  ## bot's view of it together.
  result = 0'u64
  if not l.ok or l.owner == nil:
    return
  let g = callObj(gB.boBotsGroup, l.owner)
  if g == nil:
    return
  result = cast[uint64](g)

proc nearestGrenade*(world: Il2CppPtr; at: Vec3; within: float;
                     found: var Vec3): bool =
  ## The closest live grenade to a point, if the world will name any.
  ##
  ## Called once per tick for the whole raid rather than once per bot: the list
  ## is empty on essentially every tick of a raid, and an empty list is one
  ## bound `get_Count` -- about ten nanoseconds -- which is the right price for
  ## making the highest-urgency decision in the ladder reachable at all.
  result = false
  found = zeroVec()
  if world == nil:
    return
  let list = grenadeList(world)
  if list == nil:
    return
  let n = grenadeCount(list)
  if n <= 0:
    return
  var bestSqr = within * within
  var i = 0
  while i < n:
    let g = grenadeAt(list, i)
    inc i
    if g == nil:
      continue
    let p = grenadePosition(g)
    let d = sqrDistance(at, p)
    if d < bestSqr:
      bestSqr = d
      found = p
      result = true

# ---------------------------------------------------------------------------
# Driving a bot
# ---------------------------------------------------------------------------

type
  Actuation* = object
    ## What the decision came out as, in terms the game understands. Built
    ## whether or not it can be applied, so that observer mode logs exactly what
    ## it would have done.
    sprint*: bool
    moveTo*: Vec3
    hasMoveTarget*: bool
    lookAt*: Vec3
    hasLookTarget*: bool
    shoot*: bool
    ## The self action, carried as the enum rather than as the name of the
    ## call that performs it.
    ##
    ## It was a `string` -- `"reload"`, `"firstaid"` -- compared by value in
    ## `applySelf`. That was harmless while an actuation lived and died inside
    ## one call on one thread, and it is not harmless now that one crosses to
    ## Unity's thread through a fixed ring: a nimony string is a heap object
    ## with a length, and handing one between two threads through a shared
    ## array is exactly the kind of thing that works in a test and tears in a
    ## raid. Every field of an `Actuation` is now a scalar.
    selfAct*: SelfAction

func actuationFor*(d: Decision; b: BotView): Actuation =
  ## Pure: the decision-to-intent mapping, with no game calls in it.
  ##
  ## SAIN spends thirty-odd BigBrain action classes on this, each with its own
  ## update loop. Most of them differ only in where the bot goes, how fast, and
  ## whether it is shooting, so the mapping is a function rather than a class
  ## hierarchy, and it is testable for the same reason `core/` is.
  ##
  ## **The destination comes from the decision, not from here.** This function
  ## used to set `hasMoveTarget` while leaving `moveTo` at the origin for four
  ## of its cases -- `SeekCover`, `ShiftCover`, `Retreat` and `AvoidGrenade`
  ## all told the game to walk to world zero -- and it could not do better,
  ## because only the ladder knows whether a bot is moving *to* something or
  ## *away* from it. `decide.moveTargetFor` answers that, in `core/`, where it
  ## is testable; this reads the answer.
  var a = Actuation(sprint: false, moveTo: d.moveTo,
                    hasMoveTarget: d.hasMove,
                    lookAt: b.enemy.position, hasLookTarget: b.enemy.valid,
                    shoot: false, selfAct: saNone)
  case d.combat
  of cdStandAndShoot, cdShootDistantEnemy, cdDogFight:
    a.shoot = true
  of cdSeekCover, cdShiftCover, cdRetreat:
    a.sprint = d.combat != cdShiftCover
    a.shoot = d.combat == cdRetreat and b.enemy.visible
  of cdRunAway, cdExtract:
    a.sprint = true
    a.hasLookTarget = false
  of cdRushEnemy:
    a.sprint = true
    a.shoot = b.enemy.visible
  of cdFlank:
    # Not sprinting: a flank is a move the bot wants to survive, and sprinting
    # in EFT means a lowered weapon and a great deal of noise. Looking at the
    # enemy's last known place while moving sideways is the whole posture.
    a.sprint = false
    a.shoot = b.enemy.visible and b.enemy.canShoot
  of cdMoveToEngage, cdCreepOnEnemy:
    a.sprint = d.combat == cdMoveToEngage
  of cdSearch:
    discard
  of cdAvoidGrenade:
    a.sprint = true
    a.hasLookTarget = false
  of cdMeleeAttack:
    a.sprint = true
  of cdMoveToObjective:
    # Walking, not sprinting, and looking where it is going. A squad crossing
    # the map at a sprint with weapons down is both loud and visibly wrong, and
    # the objective rung only ever fires when there is nothing to hurry for.
    a.sprint = false
    a.hasLookTarget = false
    a.shoot = false
  of cdFreeze, cdHoldInCover, cdNone:
    discard
  of cdThrowGrenade:
    a.lookAt = b.enemy.position
    a.hasLookTarget = true

  a.selfAct = d.self
  result = a

var gMoveTargetsDropped = 0
var gSelfActionsRefused = 0

# ---------------------------------------------------------------------------
# THE ONE-WRITER DECISION, and which actuator lost
# ---------------------------------------------------------------------------
#
# There were two things writing a bot's locomotion and they were fighting on
# last-writer-wins:
#
#   SERVER SIDE  `mods/sain/server/drive.nim` -> ORBIT dispatch -> the host's
#                census, ending in `BotMover::SetTargetMoveSpeed` @0x1A2B4D0
#                (`movss [rcx+0x15C], xmm1; ret`) and, through
#                `abi/aowlspt_botnav.h`, the hand-written 8-argument thunk on
#                `EFT.BotOwner::GoToPoint` @0x81CB40. Host flag `botNav`.
#
#   CLIENT SIDE  this file, per decide, via `BotMover::Sprint` @0x1A2D700.
#
# THE SERVER SIDE WINS, and the reason is not a preference. The client side
# CANNOT ISSUE A DESTINATION at all: `GoToPoint` needs 8-9 register slots and
# `AOWL_FAST_MAX_SLOTS` is 5, so `callrva` refuses rather than spilling to the
# stack. An actuator that can set "sprint" but not "where to" is not a
# locomotion actuator -- it can only make a bot run faster along a path
# somebody else chose, which is precisely the incoherent behaviour that
# last-writer-wins produces. The server side already owns a working
# destination writer. So locomotion is ITS job, whole.
#
# What the client side keeps, because nothing else writes them: LOOK
# (`BotSteering::LookToPoint`) and FIRE (`ShootData::Shoot`), plus reload.
#
# THE LOSER IS INERT, NOT SILENT. `clientDrivesLocomotion` defaults FALSE and
# `gSprintWithheld` counts every sprint call this gate refused. A run where
# the server side is driving therefore prints a NON-ZERO withheld count and a
# ZERO sprint-call count, which is what "it wrote zero times" looks like when
# it is proved rather than asserted. Turning the flag on restores the old
# two-writer behaviour deliberately, and the state line says so.
var gClientLocomotion = false
var gSprintWithheld = 0
var gSprintIssued = 0

proc setClientLocomotion*(v: bool) = gClientLocomotion = v
proc clientLocomotion*(): bool = gClientLocomotion
proc sprintWithheld*(): int = gSprintWithheld
proc sprintIssued*(): int = gSprintIssued

proc applySelf(l: BotLive; which: SelfAction): int =
  ## The self actions, each one bound call on a component two bound calls away.
  ## All three are no-argument voids, which is the one shape the fast path is
  ## unambiguously best at -- 6.5 ns measured, against ~1000 through the host.
  ##
  ## Each of the four is gated on its declared signature: `withGate(..,
  ## dsNoArgs)` in `live.bindAll` means "found at arity zero" now also means
  ## "declares no parameters", which is what `callVoidOn` handing over a null
  ## argument array requires and what nothing checked before.
  result = 0
  if l.owner == nil:
    return
  if which == saReload:
    let wm = callObj(gB.boWeapon, l.owner)
    if wm == nil: return
    let rl = callObj(gB.wmReload, wm)
    if rl == nil: return
    if callVoidOn(gB.rlTryReload, rl): result = 1
    return
  # THE THREE MEDICAL SELF-ACTIONS REFUSE, and the reason is measured rather
  # than assumed. The old code bound them at arity ZERO by name. Offline, on
  # this build, they do not exist at arity zero at all:
  #
  #   void BotFirstAid::TryApplyToCurrentPart(Nullable<int> varianAnim, Action callback)   @0x1A20740
  #   void BotStimulators::TryApply(bool noCheckDelay, Nullable<int> animVarian, Action<bool> callback) @0x1A245E0
  #   void BotSurgicalKit::ApplyToCurrentPart(Action callbackEndUse)                       @0x1A252F0
  #
  # Two things block them, and neither is worked around here:
  #
  # 1. `Nullable<int>` is an 8-BYTE by-value aggregate. Win64 passes a struct
  #    of exactly 1/2/4/8 bytes IN the register rather than by pointer, and
  #    that case has NOT been measured on this build -- `callrva.addAggregate`
  #    refuses it by name for precisely this reason. The difference between the
  #    two conventions is a call with its arguments in the wrong registers,
  #    which returns plausibly and corrupts.
  # 2. Every one of them takes a managed `Action` delegate. Passing null means
  #    betting that the callee null-checks before invoking; nothing here has
  #    measured that it does, and constructing a real delegate needs the
  #    reflective surface this mod does not use.
  #
  # So: no call, one line saying which self-action was wanted, and the decision
  # ladder carries on. `saReload` above is unaffected.
  if which == saFirstAid or which == saStims or which == saSurgery:
    inc gSelfActionsRefused
    return 0


var gDriveRefusedDying = 0
var gDriveRefusedLogged = 0

proc drivesRefusedDying*(): int = gDriveRefusedDying

proc noteDriveRefusedDying(why: string) =
  ## A refusal is the SAFE outcome, so it is not a fault and does not spend the
  ## `MaxDriveFaults` budget -- spending it here would turn a normal raid end
  ## into a permanent self-disable. It is counted always and logged for the
  ## first eight occurrences, which is enough to name the shape in a raid log
  ## without a per-frame line once a whole squad is being torn down at once.
  gDriveRefusedDying = gDriveRefusedDying + 1
  if gDriveRefusedLogged < 8:
    gDriveRefusedLogged = gDriveRefusedLogged + 1
    warn "sain drive: order REFUSED, bot is not drivable -- " & why &
         " (this is the teardown gate doing its job, not a fault)"

proc resetDriveRefusals*() =
  gDriveRefusedDying = 0
  gDriveRefusedLogged = 0
  resetDriveGateCounters()

# --- PER-DRIVE-KIND ACCOUNTING.
#
# `driveStats` already counts calls in total and names what was NOT delivered.
# What it could not say is, for ONE kind of drive call, how many times the
# decision core ORDERED it and how many times the call was actually made -- and
# those two differing is the only thing that distinguishes "the ladder never
# asked" from "the ladder asked and the channel refused". A single total cannot
# tell those apart, and at level 3 that is exactly the question.
#
# ONE reason is kept per kind, the FIRST, not the last: a channel that refuses
# for a real reason on the first order and then for a cascade of consequences
# afterwards should report the cause, not the tail.
var gLookOrdered = 0
var gLookMade = 0
var gLookRefusedWhy = ""
var gShootOrdered = 0
var gShootMade = 0
var gShootRefusedWhy = ""

proc noteDriveKind(slot: var string; why: string) =
  if slot.len == 0:
    slot = why

proc driveKindLines*(): seq[string] =
  ## One line per drive-call kind: ordered, made, and the first refusal.
  ##
  ## Written as ordered-vs-made rather than as a success count on purpose. A
  ## line reading "0 ordered, 0 made" is INCONCLUSIVE and says so; a line
  ## reading "31 ordered, 0 made" is a FAIL with a reason attached. A bare
  ## "0 calls" is indistinguishable between the two, and that ambiguity is what
  ## made every previous drive verdict unreadable.
  result = @[]
  result.add "sain DRIVE KIND look (BotSteering::LookToPoint @0x1A3B690): " &
    $gLookOrdered & " ordered, " & $gLookMade & " made, first refusal: " &
    (if gLookRefusedWhy.len > 0: gLookRefusedWhy
     elif gLookOrdered == 0: "none -- and none was possible: the decision core " &
       "never ordered a look this raid, so this channel is INCONCLUSIVE " &
       "rather than passing"
     else: "none")
  result.add "sain DRIVE KIND shoot (ShootData::Shoot): " &
    $gShootOrdered & " ordered, " & $gShootMade & " made, first refusal: " &
    (if gShootRefusedWhy.len > 0: gShootRefusedWhy
     elif gShootOrdered == 0: "none -- and none was possible: no shot was " &
       "ordered this raid, so this channel is INCONCLUSIVE rather than passing"
     else: "none")
  result.add "sain DRIVE KIND sprint (BotMover::Sprint): " &
    $(gSprintIssued + gSprintWithheld) & " ordered, " & $gSprintIssued &
    " made, first refusal: " &
    (if gSprintWithheld > 0 and not gClientLocomotion:
       "clientDrivesLocomotion is OFF, so locomotion belongs to " &
       "server/drive.nim by the one-writer rule and this actuator withheld " &
       $gSprintWithheld & " calls DELIBERATELY. This is not a failure of the " &
       "call and must not be read as one"
     else: "none")
  result.add "sain DRIVE KIND move (BotMover::GoToPoint): " &
    $gMoveTargetsDropped & " ordered, 0 made, first refusal: GoToPoint needs " &
    "8 register slots and EFT.BotOwner::GoToPoint 9; the shape dispatcher " &
    "tops out at 5 and REFUSES rather than spilling to the stack. This is a " &
    "permanent, stated refusal on this build, not a runtime failure"
  result.add "sain DRIVE KIND self (BotReload::TryReload and the three " &
    "medical applies): " & $gSelfActionsRefused & " refused. The three " &
    "medical applies are PERMANENT refusals (each stores an unchecked managed " &
    "Action for a continuation to invoke later, off any stack of ours); " &
    "TryReload is a level-3 row and binds only at sainRvaTableDriveLevel 3"

proc applyTo*(l: BotLive; a: Actuation): int =
  ## Push an actuation into the game. Returns how many calls were made, which is
  ## what the driver budgets against.
  ##
  ## Nothing is called when the bot's decision has not changed -- that check
  ## lives in the driver, because it is the driver that holds the previous
  ## actuation. Here the rule is only: one call per thing that changed.
  ##
  ## All five calls are on the fast path, and two of them only because this mod
  ## states their shape: `GoToPoint` and `LookToPoint` take a `Vector3`, which
  ## Win64 passes by hidden pointer -- a different call *shape* rather than a
  ## different register class, so `fast.bindRaw` is given the slot count
  ## directly. `live.callVec` carries the reasoning and the reflective
  ## fallback for a build where the guards do not hold.
  ##
  ## **And every one of the five is now gated on its declared signature.**
  ## `live.resolveOn` reads the runtime's own parameter types back and compares
  ## them against `core/sig.checkDrive` before anything is bound, so a
  ## `GoToPoint` whose first argument is not a `Vector3` -- which
  ## `il2cpp_class_get_method_from_name` will happily hand back, because it
  ## matches on arity -- refuses by name and this function makes no call on
  ## that channel at all. A refused channel returns zero calls, and the log
  ## says which channel and what the bot does instead.
  ##
  ## **Which thread this runs on is the caller's business and is not free.**
  ## `postDrive` below is the path a raid takes: the order is queued on the
  ## host's thread and executed inside an `onMainThread` job. This function is
  ## what that job calls, and it is also what the host-thread fallback calls.
  ## It must therefore touch no bot table and take no lock, which it does not:
  ## every pointer in it comes from its arguments.
  if not capable() or not l.ok:
    return 0

  # --- THE TEARDOWN GATE, and it is the FIRST thing in this function on
  # purpose.
  #
  # It used to be `l.ok`, which `liveOf` and `runDrives` both set to `true`
  # unconditionally once a GC handle resolved. That could not fail: we hold a
  # STRONG handle, so the target resolves for the whole raid, including after
  # `BotOwner.Dispose(withNulls:true)` has nulled the components and after
  # Unity destroyed the native halves. Driving through that is a
  # NullReferenceException raised inside the engine -- which is what
  # `errors_000.log` reported and what surfaced as `Problem bot dispose
  # (group 1) ... state:Disposed` in `aiErrors_000.log`.
  #
  # `drivable` reads Unity's own `m_CachedPtr` and the game's own `_botState`,
  # so a raid tearing down refuses here instead of calling. It is evaluated
  # HERE rather than in the driver because this is the one function both the
  # queued path (`runDrives`, next frame) and the host-thread fallback go
  # through, and the whole failure was a gap between when the bot was looked at
  # and when it was driven.
  #
  # `applySelf` is inside the gate too. `saReload` walks
  # `BotWeaponManager -> Reload -> TryReload`, and
  # `OnWeaponTaken fail ... _player._handsController != null && ReferenceEquals`
  # in the same client log is that path meeting a player whose hands controller
  # is being torn down.
  var gateWhy = ""
  if not drivable(l.player, l.owner, gateWhy):
    noteDriveRefusedDying(gateWhy)
    return 0

  var calls = 0

  if a.selfAct != saNone:
    calls = calls + applySelf(l, a.selfAct)

  if l.owner == nil:
    return calls

  # EVERY HOP AND EVERY CALL BELOW IS NOW OFFLINE-RESOLVED. `callObj(gB.boMover,
  # ..)` and friends resolved a NAME through the runtime; `drivecalls` reads a
  # MEASURED static field offset instead and calls a byte-verified static RVA.
  # Nothing here asks the export ABI for anything.

  if a.hasMoveTarget:
    # THE DESTINATION IS THE ONE THING THAT STILL DOES NOT LAND, and it must
    # say so rather than look like it worked. `BotMover::GoToPoint` @0x1A2EE00
    # takes 8 register slots including `this` and `EFT.BotOwner::GoToPoint`
    # @0x81CB40 takes 9; `AOWL_FAST_MAX_SLOTS` is 5, because Win64 puts
    # everything past the fourth argument on the STACK and the shape dispatcher
    # does not express a stack argument. `callrva` refuses rather than spills,
    # which is right.
    #
    # What DOES land, and what this reduces to today: the bot is told to stop
    # or to sprint, and it is steered. The route out is `aowlspt/botnav`, whose
    # hand-written thunk in `abi/aowlspt_botnav.h` already calls the 8-argument
    # GoToPoint correctly -- it needs the host census's bot ID, which this mod
    # does not yet map to its own `Player*`. Named in README.md, not half-built
    # here.
    inc gMoveTargetsDropped
    # The one-writer gate. Default OFF, so the server side owns locomotion and
    # this counts what it did not do.
    if not gClientLocomotion:
      inc gSprintWithheld
    else:
      let mover = moverOf(l.owner)
      if mover != nil:
        if setSprint(mover, a.sprint):
          inc gSprintIssued
          inc calls

  if a.hasLookTarget:
    inc gLookOrdered
    let st = steeringOf(l.owner)
    if st == nil:
      noteDriveKind(gLookRefusedWhy,
        "BotSteering: the component hop off EFT.BotOwner.<Steering>@0x148 " &
        "returned null or refused its guard, so nothing was called")
    elif lookToPoint(st, a.lookAt):
      inc gLookMade
      inc calls
    else:
      noteDriveKind(gLookRefusedWhy,
        "BotSteering::LookToPoint refused at the call: " & driveWhy())

  if a.shoot:
    inc gShootOrdered
    let sd = shootDataOf(l.owner)
    if sd == nil:
      noteDriveKind(gShootRefusedWhy,
        "ShootData: the component hop off EFT.BotOwner.<ShootData>@0x280 " &
        "returned null or refused its guard, so nothing was called")
    elif fireOnce(sd):
      inc gShootMade
      inc calls
    else:
      noteDriveKind(gShootRefusedWhy,
        "ShootData::Shoot refused at the call: " & driveWhy())

  result = calls

# ---------------------------------------------------------------------------
# Driving on Unity's thread
# ---------------------------------------------------------------------------
#
# The open item this file has carried since it was written, and the reason it
# stayed open: a raycast is a read that answers a bool, and a movement order is
# a command with a lifetime. `client/coverprobe.nim` moved the first kind onto
# Unity's thread and this moves the second, and the two are not the same piece
# of work.
#
# ## Why it has to move
#
# `Mover.GoToPoint` ends in `NavMeshAgent.SetDestination`, and
# `Steering.LookToPoint` ends in writing a `Transform`. Both are Unity APIs,
# and Unity's APIs are not merely undefined off the player loop -- most of them
# check the thread and throw, and a managed throw crossing a native frame does
# not unwind: it comes back as a written exception pointer, which `live.reflect`
# does read and which the *shaped* fast path has nowhere to put. So the previous
# arrangement was not "unknown, probably fine". It was a known hazard that had
# never been executed, and those two read the same in a log.
#
# ## The shape, which is the cover sampler's and is not
#
# Same skeleton: a fixed ring written by the host's thread, drained inside an
# `onMainThread` job. Three differences, each forced by this being a command
# rather than a sample.
#
#  1. **There are many in flight, not one.** A sample is rationed to ten a
#     second for the whole raid because a raycast costs the engine something.
#     An order is issued only when a decision *changed*, which in a working
#     raid is a handful a second across every bot, so the ring is drained
#     whole on each job rather than one entry at a time. It is bounded at
#     `DriveQueueSize`, and a full ring **drops** and counts rather than
#     blocking the decision thread or growing.
#  2. **The bot may have died between the post and the drain.** The order
#     carries the bot's IL2CPP GC handle rather than a pointer, and the handle
#     is resolved on the game's thread. A dead bot's handle answers null and
#     the order is discarded -- the same reason `drainCoverSample` looks its
#     bot up by id rather than by index.
#  3. **A stale order is worse than no order.** A destination is about where
#     the bot was when the decision was made. One frame of staleness is 16 ms
#     and is nothing; a queue that had backed up by a second would be steering
#     bots to where their enemies used to be. So an order older than
#     `OrderStaleSeconds` is dropped and counted, and that count is in the
#     state line next to the drops.
#
# ## Why the ring is safe across the two threads
#
# One producer (the host's thread, in `driver.tickBot`) and one consumer
# (Unity's, in the job). The producer writes a slot and *then* advances
# `gDriveWrite`; the consumer reads strictly below `gDriveWrite` and then
# advances `gDriveRead`. Neither index is ever written by both. An aligned
# 64-bit store is not torn on x64, which is the same and only assumption the
# death ring makes. The producer refuses to write when the ring is full, so a
# slot is never overwritten while the consumer may be reading it.
#
# What is *not* claimed: that the lazy bindings underneath are safe to resolve
# concurrently. They are not, and nothing needs them to be. The five driving
# members are called from exactly one thread in a session -- Unity's when the
# queue is in use, the host's when the fallback is -- and the two are chosen
# once, at the top of `driver.tickBot`, never mixed. The components on the way
# there (`AIData`, `BotOwner`) are resolved by `readSelf` on the host's thread
# before any order can exist, because a bot is read before it is decided about.

const
  DriveQueueSize = 32
    ## Orders in flight. Eight bots a tick at 10 Hz is eighty a second in the
    ## worst case where every one of them changes its mind every tick, and a
    ## frame at 60 fps drains everything posted in the last 100 ms. Thirty-two
    ## is four times the per-tick budget; a ring this deep filling up means the
    ## drain is not running, which is what the drop counter is for.
  OrderStaleSeconds = 0.35
    ## Past this an order is discarded rather than executed. Twenty frames at
    ## 60 fps: long enough that an ordinary hitch does not throw orders away,
    ## short enough that a bot is never sent where it was half a second ago.

type
  DriveOrder* = object
    ## One actuation, addressed by GC handle rather than by pointer, with
    ## nothing in it that is not a scalar.
    gcPlayer*: uint32
    postedAt*: float
    sprint*: bool
    hasMove*: bool
    hasLook*: bool
    shoot*: bool
    selfAct*: SelfAction
    moveTo*: Vec3
    lookAt*: Vec3

func emptyOrder(): DriveOrder =
  DriveOrder(gcPlayer: 0'u32, postedAt: 0.0, sprint: false, hasMove: false,
             hasLook: false, shoot: false, selfAct: saNone,
             moveTo: zeroVec(), lookAt: zeroVec())

var gDriveRing: array[DriveQueueSize, DriveOrder]
var gDriveWrite = 0
var gDriveRead = 0
var gDriveDropped = 0
var gDriveStale = 0
var gDriveGone = 0
var gDriveRun = 0
var gDriveCalls = 0
var gDriveNs = 0'i64
var gDriveHostThread = 0

proc initDriveQueue*() =
  ## Zero the ring, its indices and its counters.
  ##
  ## Called from `driver.setPreset`, and again by the self-test between its
  ## phases. The explicit zeroing is not strictly needed -- every field of a
  ## `DriveOrder` has zero for its empty value -- and it is here because
  ## `live.nim`'s note about a nimony `--app:lib` global initialised by a call
  ## is exactly the kind of thing that is true until it is not.
  ##
  ## The **counters** are reset too, and that is the part that matters outside
  ## a raid: the benchmark below posts twenty thousand orders that no bot could
  ## ever have received, and leaving those in the drop and dead-bot totals
  ## would put a number in the state line that describes a benchmark rather
  ## than a session.
  var i = 0
  while i < DriveQueueSize:
    gDriveRing[i] = emptyOrder()
    inc i
  gDriveWrite = 0
  gDriveRead = 0
  gDriveDropped = 0
  gDriveStale = 0
  gDriveGone = 0
  gDriveRun = 0
  gDriveCalls = 0
  gDriveNs = 0'i64
  gDriveHostThread = 0
  resetDriveRefusals()

proc postDrive*(b: BotHandle; a: Actuation; nowSeconds: float): bool =
  ## Queue one order. The host's thread, and the only writer.
  ##
  ## False means the ring was full, which is counted rather than retried: an
  ## order that could not be posted this tick is about a decision the bot has
  ## already made, and the next tick posts the current one instead. Retrying a
  ## stale order is the failure this queue exists to avoid.
  if b.gcPlayer == 0'u32:
    return false
  if gDriveWrite - gDriveRead >= DriveQueueSize:
    gDriveDropped = gDriveDropped + 1
    return false
  let slot = gDriveWrite mod DriveQueueSize
  gDriveRing[slot] = DriveOrder(
    gcPlayer: b.gcPlayer, postedAt: nowSeconds, sprint: a.sprint,
    hasMove: a.hasMoveTarget, hasLook: a.hasLookTarget, shoot: a.shoot,
    selfAct: a.selfAct, moveTo: a.moveTo, lookAt: a.lookAt)
  # Last, and after the slot: this is what the game's thread reads to know the
  # slot is there to read. The same ordering `gProbeBusy` has, for the same
  # reason.
  gDriveWrite = gDriveWrite + 1
  result = true

proc runDrives*(nowSeconds: float): int =
  ## Execute everything queued. **Unity's thread, and nothing else's.**
  ##
  ## Returns the number of game calls made, which is what the driver reports.
  ## Nothing here allocates, nothing here logs, nothing here touches the bot
  ## table -- the counters are plain increments on this thread's own globals,
  ## read for a log line rather than for a decision.
  result = 0
  if gDriveRead >= gDriveWrite:
    return
  let t0 = perfCounter()
  var calls = 0
  while gDriveRead < gDriveWrite:
    let o = gDriveRing[gDriveRead mod DriveQueueSize]
    gDriveRead = gDriveRead + 1
    if nowSeconds - o.postedAt > OrderStaleSeconds:
      gDriveStale = gDriveStale + 1
      continue
    let p = target(o.gcPlayer)
    if p == nil:
      # The handle itself was dropped (raid end, `releaseAll`, `detach`).
      #
      # THIS IS NOT THE DEATH CHECK, and it used to be described as one. The
      # handle we take is STRONG, so while it is held the target resolves
      # non-null no matter what happened to the bot -- it answers null only
      # once WE let go. The bot-is-dying case is caught by `drivable` inside
      # `applyTo`, on the game's own `m_CachedPtr` and `_botState`.
      gDriveGone = gDriveGone + 1
      continue
    var l = noBot()
    l.player = p
    let ai = callObj(gB.pAIData, p)
    if ai != nil:
      l.owner = callObj(gB.aiBotOwner, ai)
    l.ok = true
    var a = Actuation(sprint: o.sprint, moveTo: o.moveTo,
                      hasMoveTarget: o.hasMove, lookAt: o.lookAt,
                      hasLookTarget: o.hasLook, shoot: o.shoot,
                      selfAct: o.selfAct)
    calls = calls + applyTo(l, a)
  gDriveNs = gDriveNs + nanosBetween(t0, perfCounter())
  gDriveRun = gDriveRun + 1
  gDriveCalls = gDriveCalls + calls
  result = calls

proc noteHostThreadDrive*(calls: int) =
  ## Count a drive made on the host's own thread, so the state line can say
  ## which path a session actually took rather than which one it prefers.
  gDriveHostThread = gDriveHostThread + 1
  gDriveCalls = gDriveCalls + calls

proc drivePending*(): int = gDriveWrite - gDriveRead
proc driveDropped*(): int = gDriveDropped
proc driveStale*(): int = gDriveStale
proc driveGone*(): int = gDriveGone
proc driveRuns*(): int = gDriveRun
proc driveCalls*(): int = gDriveCalls

proc selfActionsRefused*(): int = gSelfActionsRefused
  ## How many medical self-actions were wanted and not delivered. Same reason
  ## as `moveTargetsDropped`: a refusal that is not counted is a silent one.

proc moveTargetsDropped*(): int = gMoveTargetsDropped
  ## How many times a decision produced a destination this mod could not
  ## deliver. Reported in `report()` because a silently dropped order is
  ## exactly the failure CLAUDE.md 6 forbids: a bot that steers and sprints
  ## but never walks anywhere looks, on screen, like a bug in the decision
  ## ladder rather than a missing call shape.
proc driveHostThreadRuns*(): int = gDriveHostThread

proc driveCostNs*(): int64 =
  ## What one drain cost on the game's own clock, averaged over the drains that
  ## did something. -1 when none has run -- which is the answer against any
  ## runtime with no bots in it, and is the answer this mod has today.
  if gDriveRun <= 0: return -1'i64
  result = gDriveNs div int64(gDriveRun)
