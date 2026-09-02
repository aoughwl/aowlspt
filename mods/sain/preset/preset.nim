## The preset system: `config.json` in, a resolved `Settings` out.
##
## SAIN's presets are a folder of JSON per bot type per difficulty plus a file
## per personality, served over HTTP from the server mod and edited through two
## separate GUIs. Reproducing that machinery would be reproducing the GUIs,
## which do not exist here. What is reproduced is the *shape* that matters:
##
##     global defaults
##       overridden per difficulty band
##         overridden per bot role
##           multiplied by personality
##
## and the resolution happens **once, at load**, into a table of `Settings`
## indexed by role. A bot spawning mid-raid copies one of those and applies its
## personality; it does not parse anything, look anything up by string, or touch
## the config again for the rest of the raid.
##
## That is the performance decision here. SAIN reaches a threshold through
## `Bot.Info.FileSettings.Mind.X` — a dictionary lookup keyed on a wild-spawn
## enum and a difficulty enum, cached on the bot but rebuilt whenever the preset
## changes. Here a threshold is a field of a struct the bot owns.

import aowlspt
import aowlspt/json
import ".." / core / types
import ".." / core / settings

type
  Preset* = object
    ## Everything the mod needs to make a bot, resolved.
    base*: Settings
    ## One entry per `BotRole`, in `ord(BotRole)` order. An array indexed by an
    ## enum is not available in nimony, so this is an int-indexed `seq` with
    ## `ord()` at the call site — noted because it looks like an oversight and
    ## is not.
    byRole*: seq[Settings]
    ## A forced personality, or `pNone` to let the role decide.
    forcePersonality*: Personality
    ## The difficulty band from `config.json`, as a 0..1 scalar. SAIN ships six
    ## generated presets that differ in a dozen coefficients; one scalar through
    ## `resolvedFor` reaches the same behaviour, and the per-setting overrides
    ## are the escape hatch for anything it does not cover.
    difficulty*: float
    ## Per-role difficulty band, one entry per `BotRole` in `ord(BotRole)`
    ## order, same 0..1 scale as `difficulty` and defaulted to it.
    ##
    ## This exists because it is the ONE part of the roles cascade that reaches
    ## a bot on this build. `server/drive.nim` turns a difficulty scalar into
    ## `BotMover.MoveSpeed` over `aowlspt/botnav`, and the bot census carries
    ## each bot's `WildSpawnType`, so a PER-ROLE scalar can be delivered per bot
    ## with no new RVA and no by-name lookup. Every other `roles.*` knob feeds
    ## `core/decide.nim`, which never runs -- see the note in `client/bridge.nim`.
    roleDifficulty*: seq[float]
    enabled*: bool
    ## Server-side switches, read on the server side only.
    patchBrains*: bool
    neutraliseLocationModifiers*: bool
    logDecisions*: bool
    ## Whether the five driving calls may be made from the host's own thread
    ## when the host has not confirmed that `onMainThread` reaches Unity's.
    ##
    ## This is the mod's oldest open question given a switch rather than an
    ## assumption. `GoToPoint` ends in a `NavMeshAgent` and `LookToPoint` in a
    ## `Transform`, and Unity checks the thread on most of that surface -- so
    ## the honest default is the same one `client/coverprobe.nim` takes and
    ## the cover sampler has always taken: do not call, and say so. What makes
    ## it a switch rather than a rule is that the *cost* is different. A cover
    ## sample not taken loses one sensor; an actuation not made means bots
    ## think and never move, which on a host with no per-frame drain is the
    ## whole mod doing nothing visible.
    ##
    ## Default **true**, because that is what this mod did before the queue
    ## existed and a change of default would silently stop bots moving on
    ## every host that has not grown the drain. `driveStats()` says which path
    ## a session actually took, so a log distinguishes the two.
    driveFromHostThread*: bool
    ## Whether the CLIENT-side actuator may write locomotion (BotMover::Sprint).
    ##
    ## Default FALSE, and that is the one-writer decision rather than caution.
    ## The server side (server/drive.nim, host flag `botNav`) owns locomotion
    ## because it is the only path that can issue a DESTINATION; this actuator
    ## tops out at 5 register slots and GoToPoint needs 8-9. Turning this on
    ## restores two writers on one bot and last-writer-wins between them, which
    ## is the incoherent behaviour the decision exists to remove. Off, the
    ## refusals are COUNTED (`sprintWithheld`) rather than silent.
    clientDrivesLocomotion*: bool
    ## Whether this mod may use IL2CPP **by-name** resolution at all.
    ##
    ## Default **false**, and that default is a measured fact rather than
    ## caution. On this build `il2cpp_class_from_name` /
    ## `il2cpp_class_get_method_from_name` return NON-NIL handles into
    ## UNMAPPED memory (fact #35, a two-thread controlled experiment; it is
    ## dead on Unity's own thread too). A `nil` check therefore passes and the
    ## first dereference of the returned `MethodInfo*` takes the process down.
    ##
    ## MEASURED here, `D:\Aowlspt\hostlogs\` breadcrumb run: the client died
    ## inside `bindProbe 1/2`, whose first statement is `signatureOf` --
    ## `findClass` + `findMethod` + `methodParamCount`. Nothing else in this
    ## mod's arming path resolves by name (`lazy` builds a record and resolves
    ## per receiver at CALL time; `bindMethodAs` goes through the host's own
    ## name index), which is exactly why the other ~70 bindings survived and
    ## this one did not.
    ##
    ## It is a switch and not a constant so the fact stays falsifiable: fact
    ## #35 is scope-keyed to this GameAssembly.dll, and after a Tarkov update
    ## someone can flip this to re-measure rather than re-derive. Turning it on
    ## is turning on a known process-killer on THIS build.
    allowIl2cppReflection*: bool
    ## Bot AI > Advanced > Diagnostics: bind SAIN's members from the static-RVA
    ## table in `client/rvatable.nim` instead of by name. Default FALSE, like
    ## every new live path in this repo. OFF the mod is exactly what it was --
    ## every member refused at `ensure`, nothing read. ON, 23 members are bound
    ## from byte-verified static RVAs and the ~27 that could not be resolved
    ## offline are refused BY NAME in the log rather than being retried through
    ## the token-gated by-name lookup that kills the client.
    rvaTable*: bool
    ## How much of that table may bind: 0 observer / 1 reads / 2 aim / 3 drive.
    ## Read even when `rvaTable` is false, and clamped by `setRvaDriveLevel`
    ## rather than here, so that exactly one place decides what an out-of-range
    ## number means.
    rvaDriveLevel*: int
    ## Bot AI > Loadout: a global multiplier on how much loose loot a generated
    ## bot carries. Unlike every other field above, this one reaches the game on
    ## THIS build: it is not consumed by the client decision cascade (which never
    ## ticks) but by the server's own bot generator in `mods/tarkov/emu/bots.nim`,
    ## which the server publishes it to over the shared database at load. 1.0 is
    ## stock generosity, 2.0 "crazy full", 0.0 empties pockets. Clamped [0,5].
    lootRichness*: float

const RoleCount = 8      ## must match the number of `BotRole` members

func roleFromText*(s: string): int =
  ## Index into `byRole`. Unknown names fall to scav rather than being refused:
  ## a config naming a bot type this build does not model should not stop the
  ## mod from loading.
  case s
  of "pmc": ord(brPmc)
  of "raider": ord(brRaider)
  of "boss": ord(brBoss)
  of "follower": ord(brFollower)
  of "goon": ord(brGoon)
  of "zombie": ord(brZombie)
  of "playerscav": ord(brPlayerScav)
  else: ord(brScav)

func roleName*(r: BotRole): string =
  case r
  of brScav: "scav"
  of brPmc: "pmc"
  of brRaider: "raider"
  of brBoss: "boss"
  of brFollower: "follower"
  of brGoon: "goon"
  of brZombie: "zombie"
  of brPlayerScav: "playerscav"

proc applyOverrides(s: var Settings; node: JsonRef) =
  ## Fold a JSON object of `"settingName": number` over a `Settings`.
  ##
  ## A long `case` rather than reflection, because nimony has no runtime field
  ## lookup and because an explicit list is the only way an unknown key can be
  ## *reported* rather than silently ignored — a typo in a tuning file that
  ## quietly does nothing is the worst possible failure mode for a config.
  if not node.exists or not node.isObject:
    return
  let names = node.keys()
  for key in names:
    let child = node.child(key)
    let f = child.asFloat(-99999.0)
    let b = child.asBool(false)
    case key
    of "holdGroundBaseTime": s.holdGroundBaseTime = f
    of "fightBackHealthThreshold": s.fightBackHealthThreshold = f
    of "runAwayHealthThreshold": s.runAwayHealthThreshold = f
    of "timeBeforeSearch": s.timeBeforeSearch = f
    of "searchGiveUpSeconds": s.searchGiveUpSeconds = f
    of "engageDistance": s.engageDistance = f
    of "maxPointFireDistance": s.maxPointFireDistance = f
    of "dogFightPathStart": s.dogFightPathStart = f
    of "dogFightPathEnd": s.dogFightPathEnd = f
    of "rushMaxPathDistance": s.rushMaxPathDistance = f
    of "rushMaxPathDistanceSprint": s.rushMaxPathDistanceSprint = f
    of "meleeDistance": s.meleeDistance = f
    of "creepMaxDistance": s.creepMaxDistance = f
    of "forgetEnemySeconds": s.forgetEnemySeconds = f
    of "heardTimeout": s.heardTimeout = f
    of "visionSeenTimeout": s.visionSeenTimeout = f
    of "fieldOfViewCos": s.fieldOfViewCos = f
    of "threatDecayPerSecond": s.threatDecayPerSecond = f
    of "minSeenTimeToEngage": s.minSeenTimeToEngage = f
    of "coverMinEnemyDistance": s.coverMinEnemyDistance = f
    of "maxCoverPathLength": s.maxCoverPathLength = f
    of "coverMinHeight": s.coverMinHeight = f
    of "shiftCoverResetTime": s.shiftCoverResetTime = f
    of "healHealthThreshold": s.healHealthThreshold = f
    of "surgeryHealthThreshold": s.surgeryHealthThreshold = f
    of "stimsHealthThreshold": s.stimsHealthThreshold = f
    of "reloadNoEnemyRatio": s.reloadNoEnemyRatio = f
    of "reloadInCombatAmmoRatio": s.reloadInCombatAmmoRatio = f
    of "grenadeAvoidDistance": s.grenadeAvoidDistance = f
    of "grenadeChance": s.grenadeChance = f
    of "helpStartDistance": s.helpStartDistance = f
    of "regroupStartNoEnemy": s.regroupStartNoEnemy = f
    of "squadSpreadMinDistance": s.squadSpreadMinDistance = f
    of "suppressionSeekCoverLevel": s.suppressionSeekCoverLevel = f
    of "suppressionPinnedLevel": s.suppressionPinnedLevel = f
    of "decisionHz": s.decisionHz = f
    of "farFromPlayerDistance": s.farFromPlayerDistance = f
    of "maxBotsPerTick": s.maxBotsPerTick = int(f)
    of "objectiveSplinterM": s.objectiveSplinterM = f
    of "objectiveLeashM": s.objectiveLeashM = f
    of "objectiveReachM": s.objectiveReachM = f
    of "objectiveTimeoutS": s.objectiveTimeoutS = f
    of "lootSeekAggressiveness": s.lootSeekAggressiveness = f
    of "questPoiBias": s.questPoiBias = f
    of "objectivesEnabled": s.objectivesEnabled = b
    of "squadShareObjectives": s.squadShareObjectives = b
    of "seekLoot": s.seekLoot = b
    of "seekQuestPoi": s.seekQuestPoi = b
    of "holdPositions": s.holdPositions = b
    of "huntLastKnown": s.huntLastKnown = b
    of "willSearchForEnemy": s.willSearchForEnemy = b
    of "canShiftCoverPosition": s.canShiftCoverPosition = b
    of "difficulty":
      # Handled by `loadPreset`, not here: a role's difficulty is a BAND NAME
      # ("easy".."deathwish"), not a member of `Settings`, and it is folded in
      # as `aggressionMultiplier` after the overrides pass. Named explicitly so
      # it does not fall through to the unknown-key warning below and read as a
      # typo to the next person looking at a log.
      discard
    else:
      warn "sain: config key '" & key & "' is not a setting this build knows"

func difficultyScale(name: string): float =
  ## SAIN ships six generated difficulty presets. They differ in a dozen
  ## coefficients; the single scalar here reaches the same behaviour through
  ## `resolvedFor`, and the per-setting overrides in `config.json` are the
  ## escape hatch for anything the scalar does not cover.
  case name
  of "easy": 0.15
  of "lessdifficult", "lesshard": 0.35
  of "default", "normal": 0.5
  of "harderpmcs": 0.65
  of "ilikepain", "veryhard": 0.8
  of "deathwish": 1.0
  else: 0.5

proc loadPreset*(): Preset =
  ## Read `config.json` once and resolve it.
  ##
  ## The whole document comes back in a single `configGet("")` rather than a
  ## host call per key. Forty keys is forty marshalled round trips through the
  ## ABI otherwise, and this runs while the game is loading, when the frame
  ## budget is already gone.
  var text = ""
  discard configGet("", text)
  let doc = whole(text)

  var base = defaultSettings()
  let enabled = doc.field("enabled").asBool(true)
  let difficulty = doc.field("difficulty").asText("default")
  let scale = difficultyScale(difficulty)

  applyOverrides(base, doc.field("global"))
  # The objectives block, folded in AFTER `global` and BEFORE the per-role
  # copies are taken, so every role inherits it and a role may still override
  # any single key. It is its own block rather than more keys in `global`
  # because it is one feature with one master switch, and a settings page
  # that greys the whole group when the switch is off needs the group to
  # exist as a group.
  applyOverrides(base, doc.field("objectives"))

  var roles: seq[Settings] = @[]
  var i = 0
  while i < RoleCount:
    roles.add base
    inc i

  # Per-role difficulty starts as the global band for every role, so a config
  # that names none of them behaves EXACTLY as it did before this existed --
  # every role resolves to `scale` and `server/drive.nim` emits the single
  # BotNavAll row it always emitted. That is deliberate: a new knob must not
  # change a raid until somebody sets it.
  var roleDiff: seq[float] = @[]
  var rd = 0
  while rd < RoleCount:
    roleDiff.add scale
    inc rd

  let perRole = doc.field("roles")
  if perRole.exists and perRole.isObject:
    let names = perRole.keys()
    for name in names:
      let idx = roleFromText(name)
      var s = roles[idx]
      let node = perRole.child(name)
      applyOverrides(s, node)
      roles[idx] = s
      let band = node.child("difficulty")
      if band.exists:
        # "" is not "default": an empty string is what a cleared text control
        # writes, and resolving it to 0.5 would silently OVERRIDE a global of
        # deathwish with normal. An absent or empty band inherits, full stop.
        let txt = band.asText("")
        if txt.len > 0 and txt != "inherit":
          roleDiff[idx] = difficultyScale(txt)

  let forced = personalityFromText(doc.field("forcePersonality").asText(""))

  result = Preset(
    base: base, byRole: roles, forcePersonality: forced,
    difficulty: scale, roleDifficulty: roleDiff, enabled: enabled,
    patchBrains: doc.field("server.patchBrains").asBool(true),
    neutraliseLocationModifiers:
      doc.field("server.neutraliseLocationModifiers").asBool(true),
    logDecisions: doc.field("logDecisions").asBool(false),
    driveFromHostThread:
      doc.field("driveFromHostThread").asBool(true),
    clientDrivesLocomotion:
      doc.field("clientDrivesLocomotion").asBool(false),
    allowIl2cppReflection:
      doc.field("allowIl2cppReflection").asBool(false),
    rvaTable:
      doc.field("sainRvaTable").asBool(false),
    rvaDriveLevel:
      # Absent -> 0 OBSERVER, which is the same thing a missing flag has always
      # meant here: nothing binds. A default of anything else would make an
      # older config silently start calling into the game on upgrade.
      int(doc.field("sainRvaTableDriveLevel").asFloat(0.0)),
    lootRichness: block:
      # Absent -> 1.0 (stock), never 0.0: a loot pass that read a missing knob
      # as empty is a silent regression to naked bots. Clamped so a typo in the
      # config cannot build one bot the size of a raid.
      var m = doc.field("botLoot.richnessMultiplier").asFloat(1.0)
      if m < 0.0: m = 0.0
      if m > 5.0: m = 5.0
      m)

  # The difficulty scale is folded in here rather than at every spawn: a bot
  # spawning gets `resolvedFor(preset.byRole[role], personality, scale)` and
  # that is the whole of its setup.
  var j = 0
  while j < RoleCount:
    var s = roles[j]
    s.aggressionMultiplier = roleDiff[j]
    result.byRole[j] = s
    inc j

proc settingsFor*(p: Preset; role: BotRole; personality: Personality;
                  difficulty: float): Settings =
  ## What a spawning bot gets. One struct copy and one pass of multiplies —
  ## no parsing, no lookup by string, no allocation.
  result = resolvedFor(p.byRole[ord(role)], personality, difficulty)

proc personalityFor*(p: Preset; role: BotRole; roll: float): Personality =
  ## SAIN's assignment chain — forced, then nickname, then boss table, then a
  ## weighted roll — reduced to what this port can actually observe. A forced
  ## personality wins; otherwise the role picks a bias and the roll gives one
  ## bot in three something else, so a squad is not four identical minds.
  if p.forcePersonality != pNone:
    return p.forcePersonality
  let bias = rolePersonalityBias(role)
  if roll < 0.66:
    return bias
  # The off-bias third, spread over the remaining personalities by role.
  case role
  of brPmc, brRaider: (if roll < 0.83: pGigaChad else: pRat)
  of brBoss, brGoon: (if roll < 0.83: pWreckless else: pSnappingTurtle)
  of brScav, brPlayerScav: (if roll < 0.83: pCoward else: pTimmy)
  of brFollower: (if roll < 0.83: pChad else: pTimmy)
  of brZombie: pWreckless
