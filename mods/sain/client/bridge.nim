## The client bridge: everything that touches the running game.
##
## This is the only file in the mod that knows Tarkov exists. `core/` is pure,
## `preset/` reads a config file, `server/` talks to a database — the game
## surface is all here, deliberately, because it is also the part most likely to
## break against a client update and the part that cannot be tested offline.
##
## ## What the host can and cannot do, honestly
##
## The IL2CPP host gives three things: `resolve` a type by name, `call` a member
## by name with arguments bound to their declared types, and `patch` a compiled
## method to be told when it runs. That is enough to read and drive *static*
## surface, and it is enough to be told that something happened.
##
## It is not yet enough to walk an object graph. `resolve` hands back a handle
## to a **type**; a call that returns a reference type reports
## `{"type":"EFT.Player"}` and no handle, so there is no way to get from
## `GameWorld` to `AllAlivePlayersList` to a `BotOwner` and read that bot's
## health. Bot AI is object-graph work almost by definition, so this bridge is
## written against the interface it *will* have and probes for it at runtime:
##
##  * `probe()` asks the game one question whose answer says whether object
##    handles exist yet.
##  * everything below `capable()` is skipped when they do not, and the mod
##    says so once, at load, rather than failing silently per bot per frame.
##
## The decision core runs either way — see `driver.nim`. That is not a
## consolation prize: it means the expensive half of the port is finished and
## exercised, and the day handles land the bridge is the only file that changes.
##
## ## Performance
##
## Three rules, all of them consequences of `il2cpp_runtime_invoke` boxing its
## arguments and dispatching generically:
##
##  1. **Never resolve in a loop.** Every type is a `gameType` global, resolved
##     once on first use and cached by the API.
##  2. **Read once per bot per decision, not per check.** `snapshot` does one
##     pass of reads into a plain struct; the ladder then runs entirely on
##     stack memory. SAIN's C# reads a property inside each check.
##  3. **Prefer being told over asking.** A `patch` on a method that fires when
##     something changes costs nothing while nothing changes; polling the same
##     fact costs the same every frame forever. Where the game has an event
##     shape, this file hooks it.

import aowlspt
import aowlspt/game
import ".." / core / vec
import ".." / core / types
import ".." / core / enemy

# The type surface. Named here, resolved on first use -- a type resolved at load
# time is a false negative, because the game has not loaded its assemblies when
# a mod starts.
var GameWorld = gameType("EFT.GameWorld")
var BotsController = gameType("EFT.BotsController")
var BotSpawner = gameType("EFT.BotSpawner")
var Player = gameType("EFT.Player")

type
  Capability* = enum
    ## What this host build actually supports, discovered rather than assumed.
    capNone            ## the game is not up
    capReadOnly        ## types resolve; object handles do not exist
    capFull            ## object handles exist: bots can be read and driven

var gCapability = capNone
var gAnnounced = false

proc capability*(): Capability = gCapability

proc looksLikeHandle(raw: string): bool =
  ## The host returns `"#7"` for an object it has given a handle to, and
  ## `{"type":"EFT.Player"}` for a reference it has merely described. Telling
  ## them apart is the whole capability probe.
  if raw.len >= 3 and raw[0] == '"' and raw[1] == '#':
    return true
  result = false

proc probe*(): Capability =
  ## Ask the game one question and classify the answer.
  ##
  ## `GameWorld::get_AllAlivePlayersList` is the right question because it is
  ## the first step of every path a bot mod needs and because its return is a
  ## reference type -- exactly the case that distinguishes the two capability
  ## levels.
  if not available(GameWorld):
    gCapability = capNone
    return gCapability
  let r = GameWorld.get("AllAlivePlayersList")
  if r.ok and looksLikeHandle(r.raw):
    gCapability = capFull
  else:
    gCapability = capReadOnly
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
    warn "sain: this client host resolves types but does not hand out " &
         "handles to objects a call returns, so per-bot state cannot be " &
         "reached. The decision core is running in observer mode; nothing " &
         "is being driven. See the note at the top of client/bridge.nim."
  of capFull:
    success "sain: object handles are available; driving bots"

proc capable*(): bool = gCapability == capFull

# ---------------------------------------------------------------------------
# Reading a bot
# ---------------------------------------------------------------------------

type
  BotHandle* = object
    ## A bot, as this bridge addresses it.
    ##
    ## `handle` is the host handle when there is one. `id` is the profile id and
    ## is the key everything else uses, because it survives a handle being
    ## released and it is what the decision core keys its per-bot state on.
    id*: string
    handle*: Handle
    role*: BotRole

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

proc callOn(h: Handle; member: string): CallResult =
  ## Invoke a member on an object handle. The `#N::Member` form is the host's
  ## own; wrapping it keeps the `$` and the `#` out of every call site.
  result = CallResult(ok: false, raw: "", error: "")
  if h == 0:
    result.error = "no handle"
    return
  var out1 = ""
  let st = call("#" & $int(h) & "::" & member, "[]", out1)
  if st == Ok:
    result.ok = true
    result.raw = out1
  else:
    result.error = lastError()

proc readVec(h: Handle; member: string): Vec3 =
  ## A Vector3 comes back as text. Parsed rather than marshalled because the
  ## ABI has no struct-return path; three reads would be three invokes, which
  ## is the more expensive of the two.
  let r = callOn(h, member)
  if not r.ok: return zeroVec()
  var nums: seq[float] = @[]
  var cur = ""
  for ch in r.raw:
    if (ch >= '0' and ch <= '9') or ch == '.' or ch == '-':
      cur.add ch
    else:
      if cur.len > 0:
        var tmp = CallResult(ok: true, raw: cur, error: "")
        nums.add asFloat(tmp, 0.0)
        cur = ""
  if cur.len > 0:
    var tmp = CallResult(ok: true, raw: cur, error: "")
    nums.add asFloat(tmp, 0.0)
  if nums.len >= 3:
    result = vec3(nums[0], nums[1], nums[2])
  else:
    result = zeroVec()

proc readSelf*(b: BotHandle): SelfView =
  ## One pass of reads into a plain struct.
  ##
  ## Every field here is one `call`, and the whole point of doing them together
  ## is that the ladder afterwards touches none of them again. Adding a read
  ## inside a decision check would put an IL2CPP invoke on a path that runs a
  ## dozen times per bot per decision.
  result = SelfView(
    healthNormalized: 1.0, energy: 1.0, hydration: 1.0, stamina: 1.0,
    hasHeavyBleed: false, hasLightBleed: false, hasFracture: false,
    canHeal: false, canUseStims: false, canDoSurgery: false,
    ammoInMagazine: 30, magazineSize: 30, hasAmmoToReload: false,
    weaponReady: true, inCoverStatus: csFarFromCover, coverPointDistance: 99.0,
    suppressionLevel: 0.0, isSprinting: false, position: zeroVec(),
    lookDirection: vec3(1.0, 0.0, 0.0))
  if not capable() or b.handle == 0:
    return
  let hp = callOn(b.handle, "get_HealthPercent")
  if hp.ok: result.healthNormalized = clampf(asFloat(hp, 1.0), 0.0, 1.0)
  let sprint = callOn(b.handle, "get_IsSprintEnabled")
  if sprint.ok: result.isSprinting = asBool(sprint, false)
  result.position = readVec(b.handle, "get_Position")
  result.lookDirection = readVec(b.handle, "get_LookDirection")

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
    ## The self action, mapped to the game call that performs it.
    selfCall*: string

func actuationFor*(d: Decision; b: BotView): Actuation =
  ## Pure: the decision-to-intent mapping, with no game calls in it.
  ##
  ## SAIN spends thirty-odd BigBrain action classes on this, each with its own
  ## update loop. Most of them differ only in where the bot goes, how fast, and
  ## whether it is shooting, so the mapping is a function rather than a class
  ## hierarchy, and it is testable for the same reason `core/` is.
  var a = Actuation(sprint: false, moveTo: zeroVec(), hasMoveTarget: false,
                    lookAt: b.enemy.position, hasLookTarget: b.enemy.valid,
                    shoot: false, selfCall: "")
  case d.combat
  of cdStandAndShoot, cdShootDistantEnemy, cdDogFight:
    a.shoot = true
  of cdSeekCover, cdShiftCover, cdRetreat:
    a.sprint = d.combat != cdShiftCover
    a.hasMoveTarget = true
    a.shoot = d.combat == cdRetreat and b.enemy.visible
  of cdRunAway:
    a.sprint = true
    a.hasMoveTarget = true
    a.hasLookTarget = false
  of cdRushEnemy:
    a.sprint = true
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
    a.shoot = b.enemy.visible
  of cdMoveToEngage, cdCreepOnEnemy:
    a.sprint = d.combat == cdMoveToEngage
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
  of cdSearch:
    a.moveTo = b.searchTarget
    a.hasMoveTarget = b.hasSearchTarget
  of cdAvoidGrenade:
    a.sprint = true
    a.hasMoveTarget = true
    a.hasLookTarget = false
  of cdMeleeAttack:
    a.sprint = true
    a.moveTo = b.enemy.position
    a.hasMoveTarget = true
  of cdFreeze, cdHoldInCover, cdNone:
    discard
  of cdThrowGrenade:
    a.lookAt = b.enemy.position
    a.hasLookTarget = true

  case d.self
  of saReload: a.selfCall = "TryReload"
  of saFirstAid: a.selfCall = "TryHeal"
  of saStims: a.selfCall = "TryStims"
  of saSurgery: a.selfCall = "TrySurgery"
  of saNone: discard
  result = a

proc apply*(b: BotHandle; a: Actuation): int =
  ## Push an actuation into the game. Returns how many calls were made, which
  ## is what the driver budgets against.
  ##
  ## Nothing is called when the bot's state has not changed — that check lives
  ## in the driver, because it is the driver that holds the previous
  ## actuation. Here the rule is only: one call per thing that changed.
  if not capable() or b.handle == 0:
    return 0
  var calls = 0
  if a.selfCall.len > 0:
    discard callOn(b.handle, a.selfCall)
    inc calls
  if a.hasMoveTarget:
    var out1 = ""
    discard call("#" & $int(b.handle) & "::GoToPoint",
                 "[" & $a.moveTo.x & "," & $a.moveTo.y & "," &
                 $a.moveTo.z & "," & (if a.sprint: "true" else: "false") & "]",
                 out1)
    inc calls
  result = calls
