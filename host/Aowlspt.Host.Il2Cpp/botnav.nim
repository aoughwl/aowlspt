# botnav.nim -- NATIVE BOT NAVIGATION API. `include`d into `aowlhost.nim` (NOT a
# separate module) so it shares that file's guarded raw primitives, `cRegsInt`,
# logging (`okLog`/`info`/`warn`), `hexOf`, `cNowMs`, `attachDrain`, the VEH/SEH
# guard and the host-thread id -- the exact discipline `botai.nim`, `botcap.nim`
# and the botdiag census use.
#
# ## What this is
#
# A first-class bot registry plus ONE proven movement command, meant as the
# foundation other things (spawn control, behaviour tuning) become ordinary
# consumers of rather than bespoke hacks. Concretely:
#
#   * a live registry of every bot in the raid -- id, role, difficulty, position,
#     alive-state -- refreshed every frame with no enumeration and no GameWorld
#     walk;
#   * "bot N, go to point P", issued as a DIRECT CALL to
#     `EFT.BotOwner::GoToPoint` @0x81CB40, whose return value tells us whether
#     the point was reachable;
#   * "bot N, stop" and "bot N, move at speed S";
#   * commands arriving over the EXISTING `modSyncMs` poll against `backendPort`,
#     and the registry going back the same way on the existing report path. No
#     new socket, no new thread, no new channel.
#
# ## Why ONE hook does all of it: EFT.BotOwner::UpdateManual @0x81B7C0
#
# `BotsList::UpdateByUnity` (0x1BD6510) is its only caller, so UpdateManual runs
# once per LIVE bot per FRAME, on the Unity main thread, only inside a raid, with
# RCX = that BotOwner. That single fact collapses the whole design:
#
#   * it is the census -- every bot announces itself every frame, so we never
#     walk `GameWorld.RegisteredPlayers` and never have to resolve a `Player`
#     back to its `BotOwner` (which is genuinely ambiguous: `Player.AIData` is an
#     `IAIData` with two implementations at different offsets, and reflection is
#     dead). The BotOwner is simply handed to us;
#   * it is the service tick -- each bot's own pending command is issued while
#     that bot's own UpdateManual runs, so there is no iteration over a list of
#     possibly-stale pointers;
#   * it is uncontended -- as of kind=15 nothing else in this host detours it.
#     Anything that later wants UpdateManual must RIDE kind 15 (the
#     debugui/modetext slot-aliasing pattern), never re-detour it: a second
#     detour on one function overwrites the first's trampoline.
#
# ## Safety
#
# Whole body under ONE `aowl_p_p_seh` (never nested -- that guard is not
# re-entrant and an inner one would disarm the outer on return). Every pointer
# hop VirtualQuery-guarded via `abi/aowlspt_botnav.h`. Fixed-size registry, so no
# allocation on the per-frame path at all. Commands re-issued on a 500 ms
# throttle, never per frame, because `GoToPoint` runs `CalcPath` and allocates a
# managed path -- per-frame managed allocation has already cost this host one
# test cycle. Self-disables after `BnMaxFaults` trapped faults. Flag-gated
# `botNav`, default OFF.
#
# The full recon -- RVAs, disassembly, the ABI proof, and the honest list of what
# is NOT reachable this way -- is in `docs/BOTNAV.md` and `abi/aowlspt_botnav.h`.

# ---- offsets, targets and the direct calls from abi/aowlspt_botnav.h ----
proc cBnOffMover(): int32 {.importc: "aowl_bn_off_mover", nodecl.}
proc cBnOffProfileId(): int32 {.importc: "aowl_bn_off_profileid", nodecl.}
proc cBnOffId(): int32 {.importc: "aowl_bn_off_id", nodecl.}
proc cBnOffPlayer(): int32 {.importc: "aowl_bn_off_player", nodecl.}
proc cBnOffIsDead(): int32 {.importc: "aowl_bn_off_isdead", nodecl.}
proc cBnOffSettings(): int32 {.importc: "aowl_bn_off_settings", nodecl.}
proc cBnOffRole(): int32 {.importc: "aowl_bn_off_role", nodecl.}
proc cBnOffDiff(): int32 {.importc: "aowl_bn_off_diff", nodecl.}
proc cBnOffSDist(): int32 {.importc: "aowl_bn_off_sdist", nodecl.}
proc cBnOffMoveCtx(): int32 {.importc: "aowl_bn_off_movectx", nodecl.}
proc cBnOffPrevPos(): int32 {.importc: "aowl_bn_off_prevpos", nodecl.}

proc cBotNavTargetAt(i: int32): Il2CppPtr {.importc: "aowl_botnav_target_at", nodecl.}
proc cBotNavTargetName(i: int32): Il2CppPtr {.importc: "aowl_botnav_target_name", nodecl.}
proc cBotNavTargetCount(): int32 {.importc: "aowl_botnav_target_count", nodecl.}
proc cBotNavCallsOk(): int32 {.importc: "aowl_botnav_calls_ok", nodecl.}

proc cBnReadI32(p: Il2CppPtr; off: int32; ok: var int32): int32 {.
  importc: "aowl_botnav_read_i32", nodecl.}
proc cBnReadPtr(p: Il2CppPtr; off: int32; ok: var int32): Il2CppPtr {.
  importc: "aowl_botnav_read_ptr", nodecl.}
proc cBnReadU8(p: Il2CppPtr; off: int32; ok: var int32): int32 {.
  importc: "aowl_botnav_read_u8", nodecl.}
proc cBnReadF32(p: Il2CppPtr; off: int32; ok: var int32): float64 {.
  importc: "aowl_botnav_read_f32", nodecl.}
proc cBnReadV3(p: Il2CppPtr; off: int32; outv: ptr float64): int32 {.
  importc: "aowl_botnav_read_v3", nodecl.}

proc cBnGoto(owner: Il2CppPtr; x, y, z, reach: float64;
             slow, force: int32): int32 {.importc: "aowl_botnav_goto", nodecl.}
proc cBnStop(owner: Il2CppPtr): int32 {.importc: "aowl_botnav_stop", nodecl.}
proc cBnSetSpeed(owner: Il2CppPtr; speed: float64): int32 {.
  importc: "aowl_botnav_set_speed", nodecl.}

# The slot/flag/counter globals (gBotNavSlot / gBotNav / gBotNavFires /
# gBotNavFaults / gBotNavOff) are declared in aowlhost.nim beside the other
# detour slots.

const
  BnMaxBots = 48
    ## Registry capacity. An offline raid runs well under this; a bot arriving
    ## past the cap is simply not registered (and says so once) rather than
    ## growing an array on the Unity thread.
  BnMaxCmds = 16
    ## Most commands one poll may carry.
  BnReissueMs = 500'i64
    ## How often an active command is RE-issued. The bot's brain re-evaluates its
    ## goal every tick and will re-target the mover, so a single GoToPoint is
    ## advisory and typically overridden within a frame or two -- holding a bot
    ## on our destination means saying it again. NOT per frame: GoToPoint runs
    ## CalcPath and allocates a managed path.
  BnDefaultHoldMs = 20000'i64
    ## How long a command stays active if the caller named no hold.
  BnMaxHoldMs = 600000'i64
  BnArriveDist = 2.0
    ## Below this `BotMover.SDistDestination` we call it arrived and stop
    ## re-issuing.
  BnMaxFaults = 8
    ## Trapped faults before the whole feature switches itself off for the run.
  BnStaleMs = 5000'i64
    ## A registry row untouched for this long is treated as gone (bot despawned,
    ## raid ended) and its slot is reused. Its pointer is NEVER dereferenced
    ## again -- only rows refreshed by a live UpdateManual fire are commandable.
  BnCensusMs = 4000'i64
    ## Census rebuild cadence for the report/log. Off the per-frame path.
  BnCensusBudget = 110
    ## Characters of census one poll may carry. `ReportMaxPath` is 191 for the
    ## WHOLE path -- route, mod-outcome rows and this -- because the overlay's
    ## sync worker copies the path into a 192-byte field and truncates silently
    ## beyond it. A record is about 20 characters, so this is roughly five bots
    ## per poll, and the census rotates through the rest on later polls. If the
    ## mod rows have already eaten the budget the census is dropped whole for
    ## that poll rather than truncated: half a coordinate list is worse than
    ## none, and the next poll carries the current truth anyway.

type
  BnEntry = object
    owner: uint64          ## the BotOwner pointer, as last seen live
    id: int32              ## EFT.BotOwner.Id  (+0x408)
    role: int32            ## BotSettings._role, WildSpawnType (+0x14)
    diff: int32            ## BotSettings._difficulty (+0x10)
    dead: bool
    x, y, z: float64       ## MovementContext.PreviousPosition
    posKnown: bool         ## x/y/z hold a real reading, not the initial zeroes
    moved: bool            ## position has CHANGED at least once since then
    lastSeen: int64
    used: bool
    # --- active command ---
    hasCmd: bool
    cx, cy, cz: float64
    reach: float64
    sprint: bool
    cmdUntil: int64
    nextIssue: int64
    issues: int32
    status: int32          ## last NavMeshPathStatus: 0 Complete, 1 Partial,
                           ## 2 Invalid, -1 none, -2 pre-flight refused
    # A one-shot instruction owed on this bot's NEXT tick, kept separate from the
    # standing destination above. They are separate because they genuinely are:
    # `moveSpeed` does not cancel a destination, and folding it into the
    # destination's own fields would have a speed command silently overwrite the
    # reach distance of a goto that is still running.
    pend: int32            ## 0 nothing, 1 StopMove, 2 SetTargetMoveSpeed
    pendSpeed: float64
  BnCmd = object
    id: int32              ## bot Id, or -1 for "every registered bot"
    stop: bool
    speedOnly: bool
    x, y, z: float64
    reach: float64
    speed: float64
    sprint: bool
    holdMs: int64

var gBnReg: array[BnMaxBots, BnEntry]

# The command handoff is a LOCK-FREE DOUBLE BUFFER, and the shape is deliberate.
#
# The obvious alternative -- a flag the two sides spin on -- is not acceptable
# here: one of the two sides is the Unity main thread inside a bot's Update, and
# a spin on a plain `bool` that the C compiler is free to hoist out of the loop
# turns a rare contention into a hung game. `tablesLock` is no better; it is a
# lock a mod's `patch` also takes, and putting it on a per-frame path would couple
# the game's frame time to whatever a mod is doing.
#
# So instead: the poll thread fills the buffer the Unity thread is NOT reading,
# and only then publishes the generation. The Unity thread reads the generation
# once, and if it moved, reads the buffer that generation names. A new publish
# can only ever touch the other buffer, so the read cannot be torn by one writer.
# Two publishes during a single read would be needed to catch it, and the writer
# runs every `modSyncMs` (3 s by default) against a read that takes microseconds.
var gBnWant: array[2, array[BnMaxCmds, BnCmd]]
var gBnWantN: array[2, int]
var gBnGen = 0
  ## Bumped by the POLL thread, LAST, after the buffer it names is filled. Its
  ## low bit selects the buffer.
var gBnApplied = -1
  ## Last generation consumed by the UNITY thread. The per-frame path reads one
  ## aligned int and, when it matches, touches the shared table not at all --
  ## the same "only when it actually changed" discipline modetext uses.
var gBnCensusAt = 0'i64
var gBnCensus = ""
var gBnCensusCursor = 0
  ## Where the next census starts. See `bnBuildCensus` -- the path budget cannot
  ## carry the whole registry, so it rotates.
var gBnIssued = 0
var gBnCapWarned = false
var gBnCallsChecked = false

proc bnSanePtr(p: Il2CppPtr): bool =
  ## Cheap plausibility gate before any probe: a real IL2CPP object pointer lives
  ## in canonical user space, above the null page and below the non-canonical
  ## hole. The C side re-checks with VirtualQuery; this just avoids the syscall
  ## for an obviously bogus value.
  let v = cast[uint64](p)
  result = v >= 0x10000'u64 and v < 0x00007FFFFFFFFFFF'u64

# ---------------------------------------------------------------------------
# Command intake -- runs on the POLL thread, never the Unity thread.
# ---------------------------------------------------------------------------

proc bnSetWanted*(cmds: seq[BnCmd]) =
  ## Publish a new command set. Called from `takeModSet` on the POLL thread after
  ## `parseDesired` has accepted the document.
  ##
  ## Writes the buffer the Unity thread is not reading, and bumps the generation
  ## LAST -- the generation is the publish, so it must not move until the data it
  ## names is complete. See the note on the buffers above for why this is not a
  ## lock.
  let slot = (gBnGen + 1) and 1
  var n = cmds.len
  if n > BnMaxCmds:
    n = BnMaxCmds
  for i in 0 ..< n:
    gBnWant[slot][i] = cmds[i]
  gBnWantN[slot] = n
  gBnGen = gBnGen + 1

# There is no "take a copy" step on the Unity side, and that is deliberate
# rather than an omission. The double buffer already guarantees the writer is
# never touching the slot the current generation names, so copying it into a
# local would buy nothing and cost a 16-element array the Unity thread would
# have to initialise on every generation change. `bnApplyGeneration` reads
# `gBnWant[slot]` in place.

proc bnParseFloat(s: string; into: var float64): bool =
  ## Small, total float reader: optional sign, digits, optional fraction. No
  ## exponent, no locale, no exceptions -- this parses a coordinate off a wire
  ## string inside an injected DLL and a partial parse must be a refusal, not a
  ## surprise value.
  if s.len == 0 or s.len > 24:
    return false
  var i = 0
  var neg = false
  if s[0] == '-':
    neg = true
    i = 1
  elif s[0] == '+':
    i = 1
  var seen = 0
  var whole = 0.0
  while i < s.len and s[i] >= '0' and s[i] <= '9':
    whole = whole * 10.0 + float64(ord(s[i]) - ord('0'))
    inc i
    inc seen
  if i < s.len and s[i] == '.':
    inc i
    var scale = 0.1
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      whole = whole + float64(ord(s[i]) - ord('0')) * scale
      scale = scale * 0.1
      inc i
      inc seen
  if i != s.len or seen == 0:
    return false
  # A coordinate outside this box is not a place on any EFT map; refuse rather
  # than hand the navmesh a number that came from a typo.
  if whole > 100000.0:
    return false
  into = (if neg: -whole else: whole)
  result = true

proc bnParseInt(s: string; into: var int32): bool =
  if s.len == 0 or s.len > 11:
    return false
  var i = 0
  var neg = false
  if s[0] == '-':
    neg = true
    i = 1
  var v = 0
  var seen = 0
  while i < s.len:
    if s[i] < '0' or s[i] > '9':
      return false
    v = v * 10 + (ord(s[i]) - ord('0'))
    if v > 2000000000:
      return false
    inc i
    inc seen
  if seen == 0:
    return false
  into = int32(if neg: -v else: v)
  result = true

proc bnSplit(s: string; sep: char): seq[string] =
  result = @[]
  var cur = ""
  for ch in s:
    if ch == sep:
      result.add cur
      cur = ""
    else:
      cur.add ch
  result.add cur

proc bnParseCommands*(spec: string): seq[BnCmd] =
  ## Decode the `botNav` wire string into commands. The grammar is deliberately a
  ## single flat scalar rather than a JSON array: it rides `pathGet` verbatim
  ## like `menuModeText` does, it is length- and charset-gated in one place, and
  ## every field is validated before anything reaches a game pointer.
  ##
  ##   commands := command (';' command)*
  ##   command  := id '|' 'stop'
  ##             | id '|' 'speed' '|' <0..1>
  ##             | id '|' x '|' y '|' z [ '|' reach [ '|' sprint [ '|' holdMs ]]]
  ##   id       := <int32> | 'all'
  ##
  ## Examples:
  ##   "7|213.5|1.4|-58.2"                 bot 7 -> that point, defaults
  ##   "7|213.5|1.4|-58.2|2.0|1|30000"     ... reach 2 m, sprinting, hold 30 s
  ##   "all|stop"                          everyone stands still
  ##   "3|speed|0.5"                       bot 3 walks at half speed
  ##
  ## Anything malformed is DROPPED -- that command only, not the whole set.
  result = @[]
  for raw in bnSplit(spec, ';'):
    let part = strip(raw)
    if part.len == 0:
      continue
    if result.len >= BnMaxCmds:
      break
    let f = bnSplit(part, '|')
    if f.len < 2:
      continue
    var c = BnCmd(id: -1'i32, stop: false, speedOnly: false,
                  x: 0.0, y: 0.0, z: 0.0, reach: 1.0, speed: 1.0,
                  sprint: false, holdMs: BnDefaultHoldMs)
    let who = strip(f[0])
    if who != "all":
      if not bnParseInt(who, c.id):
        continue
      if c.id < 0:
        continue
    let verb = strip(f[1])
    if verb == "stop":
      c.stop = true
      result.add c
      continue
    if verb == "speed":
      if f.len < 3 or not bnParseFloat(strip(f[2]), c.speed):
        continue
      if c.speed < 0.0 or c.speed > 1.0:
        continue
      c.speedOnly = true
      result.add c
      continue
    if f.len < 4:
      continue
    if not bnParseFloat(verb, c.x): continue
    if not bnParseFloat(strip(f[2]), c.y): continue
    if not bnParseFloat(strip(f[3]), c.z): continue
    if f.len >= 5:
      if not bnParseFloat(strip(f[4]), c.reach): continue
      if c.reach < 0.25 or c.reach > 50.0: continue
    if f.len >= 6:
      var sp: int32 = 0
      if not bnParseInt(strip(f[5]), sp): continue
      c.sprint = sp != 0
    if f.len >= 7:
      var hold: int32 = 0
      if not bnParseInt(strip(f[6]), hold): continue
      if hold <= 0: continue
      c.holdMs = int64(hold)
      if c.holdMs > BnMaxHoldMs: c.holdMs = BnMaxHoldMs
    result.add c

# ---------------------------------------------------------------------------
# The registry + service tick -- Unity thread only, under the SEH guard.
# ---------------------------------------------------------------------------

proc bnFind(owner: uint64; now: int64): int =
  ## Row index for this BotOwner, allocating one if it is new. -1 when full.
  ## Also reaps rows nothing has refreshed for `BnStaleMs` -- a despawned bot's
  ## pointer must never be reused.
  var free = -1
  for i in 0 ..< BnMaxBots:
    if gBnReg[i].used:
      if gBnReg[i].owner == owner:
        return i
      if now - gBnReg[i].lastSeen > BnStaleMs:
        gBnReg[i].used = false
        if free < 0: free = i
    else:
      if free < 0: free = i
  if free < 0:
    return -1
  gBnReg[free] = BnEntry(owner: owner, id: -1'i32, role: -1'i32, diff: -1'i32,
                         dead: false, x: 0.0, y: 0.0, z: 0.0,
                         posKnown: false, moved: false,
                         lastSeen: now, used: true, hasCmd: false,
                         cx: 0.0, cy: 0.0, cz: 0.0, reach: 1.0, sprint: false,
                         cmdUntil: 0'i64, nextIssue: 0'i64, issues: 0'i32,
                         status: -1'i32, pend: 0'i32, pendSpeed: 1.0)
  result = free

proc bnApplyGeneration(now: int64) =
  ## Fold a newly-arrived command set into the registry. Runs on the Unity thread
  ## at most once per generation, not per bot and not per frame.
  # `gen` is read ONCE, here, and is what both the buffer selection and the
  # "applied" mark are derived from. Re-reading it for the mark would let a
  # publish landing mid-loop record a newer generation as applied than the one
  # actually read, silently dropping a command set.
  let gen = gBnGen
  let slot = gen and 1
  let n = gBnWantN[slot]
  gBnApplied = gen
  for k in 0 ..< n:
    let c = gBnWant[slot][k]
    for i in 0 ..< BnMaxBots:
      if not gBnReg[i].used:
        continue
      if c.id >= 0 and gBnReg[i].id != c.id:
        continue
      if c.stop:
        gBnReg[i].hasCmd = false
        gBnReg[i].status = -1'i32
        # The stop itself is issued on this bot's next tick, where UpdateManual
        # has just handed us a pointer we know is live. Nothing is CALLED from
        # here: this runs inside whichever bot happened to tick first, and its
        # BotOwner is the only one we may touch.
        gBnReg[i].pend = 1'i32
        continue
      if c.speedOnly:
        gBnReg[i].pend = 2'i32
        gBnReg[i].pendSpeed = c.speed
        continue
      gBnReg[i].hasCmd = true
      gBnReg[i].cx = c.x
      gBnReg[i].cy = c.y
      gBnReg[i].cz = c.z
      gBnReg[i].reach = c.reach
      gBnReg[i].sprint = c.sprint
      gBnReg[i].cmdUntil = now + c.holdMs
      gBnReg[i].nextIssue = now
      gBnReg[i].issues = 0'i32
      gBnReg[i].status = -1'i32

proc bnRefresh(i: int; owner: Il2CppPtr; now: int64) =
  ## Read this bot's cheap identity + position. Every hop is guarded; a hop that
  ## does not read simply leaves the previous value in place.
  var ok = 0'i32
  let idv = cBnReadI32(owner, cBnOffId(), ok)
  if ok != 0'i32: gBnReg[i].id = idv
  let dead = cBnReadU8(owner, cBnOffIsDead(), ok)
  if ok != 0'i32: gBnReg[i].dead = dead != 0'i32
  if gBnReg[i].role < 0:
    let st = cBnReadPtr(owner, cBnOffSettings(), ok)
    if ok != 0'i32 and bnSanePtr(st):
      let r = cBnReadI32(st, cBnOffRole(), ok)
      if ok != 0'i32: gBnReg[i].role = r
      let d = cBnReadI32(st, cBnOffDiff(), ok)
      if ok != 0'i32: gBnReg[i].diff = d
  let pl = cBnReadPtr(owner, cBnOffPlayer(), ok)
  if ok != 0'i32 and bnSanePtr(pl):
    let mc = cBnReadPtr(pl, cBnOffMoveCtx(), ok)
    if ok != 0'i32 and bnSanePtr(mc):
      # Initialised explicitly: nimony will not take the address of a local it
      # cannot prove was written, and "the C function fills it" is not a proof
      # it has.
      var v: array[3, float64] = [0.0, 0.0, 0.0]
      if cBnReadV3(mc, cBnOffPrevPos(), addr v[0]) != 0'i32:
        # "Has this bot ever actually moved?" is the empirical proof that its
        # BotMover state machine is populated -- the one hop inside
        # BotMover::GoToPoint we cannot check statically (a Dictionary lookup
        # whose miss is a managed throw). We only ever command a bot that has
        # already demonstrated it can move.
        #
        # `posKnown` matters: without it the FIRST reading is compared against
        # the row's initial zeroes, which is a delta of hundreds of metres for
        # any bot not standing on the world origin -- so every bot would be
        # declared "moved" the instant it registered and the gate would protect
        # nothing at all. The first reading only establishes a baseline.
        if not gBnReg[i].posKnown:
          gBnReg[i].posKnown = true
        elif not gBnReg[i].moved:
          let dx = v[0] - gBnReg[i].x
          let dy = v[1] - gBnReg[i].y
          let dz = v[2] - gBnReg[i].z
          if (dx*dx + dy*dy + dz*dz) > 0.0025:
            gBnReg[i].moved = true
        gBnReg[i].x = v[0]
        gBnReg[i].y = v[1]
        gBnReg[i].z = v[2]
  gBnReg[i].lastSeen = now

# ---------------------------------------------------------------------------
# ISSUE LOGGING: loud the first time, counted after that.
#
# `bnService` logged EVERY successful `SetSpeed` and `StopMove` at `ok`.
# MEASURED on one 761 s host log: 9,201 lines -- 36.4% of the whole file, 12
# lines/s -- were the single statement `botnav: bot id=N move speed -> N.NN`.
# That is more of that log than the maps diag block and the backend's request
# log put together.
#
# It is NOT gated away, because it is the only evidence in the log that botnav
# is issuing anything at all, and a feature that works silently is the failure
# mode this project treats as worst-case. Instead: the FIRST issue of each kind
# announces itself in full, naming the bot and the value, and every issue after
# that is counted into a rollup emitted at most once per 10 s.
#
# Precisely what survives, stated so nobody has to assume: the per-bot detail
# line appears ONCE PER SESSION per kind -- these counters are session-scoped,
# NOT reset per raid, because botnav has no per-raid reset hook to hang that on
# and inventing one here would be a guess. What DOES appear in every raid that
# has bot activity is the rollup, within 10 s of that raid's first issue,
# carrying both the interval count and the session totals. So "botnav issued
# commands in this raid" remains readable from a quiet log; "which bot, at what
# speed, the first time" is a once-per-session detail. An issue that FAILS is
# untouched by any of this and still logs at its own site.
const BnRollupMs = 10000'i64

var gBnSpeedTotal = 0'i64
var gBnStopTotal = 0'i64
var gBnSpeedSince = 0'i64
var gBnStopSince = 0'i64
var gBnRollupAt = 0'i64

proc bnRollup(now: int64) =
  ## One line for everything issued since the last one. Emitted only when
  ## something WAS issued, so it is never a heartbeat for an idle raid -- an
  ## idle raid is already described by the absence of issues after the first.
  if gBnSpeedSince == 0'i64 and gBnStopSince == 0'i64:
    return
  if gBnRollupAt != 0'i64 and now - gBnRollupAt < BnRollupMs:
    return
  let prev = gBnRollupAt
  gBnRollupAt = now
  okLog "botnav: issued " & $gBnSpeedSince & " speed change(s) and " &
        $gBnStopSince & " stop(s) in the last " &
        $((if prev == 0'i64: BnRollupMs else: now - prev) div 1000'i64) & "s " &
        "(session totals: " & $gBnSpeedTotal & " speed, " & $gBnStopTotal &
        " stop). Per-issue lines are logged for the FIRST of each kind only; " &
        "this rollup replaced 12 lines/s of them."
  gBnSpeedSince = 0'i64
  gBnStopSince = 0'i64

proc bnService(i: int; owner: Il2CppPtr; now: int64) =
  ## Issue whatever this bot owes, at most once per `BnReissueMs`.
  if gBnReg[i].pend == 1'i32:
    gBnReg[i].pend = 0'i32
    if cBnStop(owner) != 0'i32:
      inc gBnStopTotal
      if gBnStopTotal == 1'i64:
        okLog "botnav: bot id=" & $int(gBnReg[i].id) & " StopMove issued " &
              "(the FIRST of this session -- subsequent stops are counted " &
              "into the 10s rollup instead of logged one per line)"
      else:
        inc gBnStopSince
        bnRollup(now)
    return
  if gBnReg[i].pend == 2'i32:
    let s = gBnReg[i].pendSpeed
    gBnReg[i].pend = 0'i32
    if cBnSetSpeed(owner, s) != 0'i32:
      inc gBnSpeedTotal
      if gBnSpeedTotal == 1'i64:
        okLog "botnav: bot id=" & $int(gBnReg[i].id) & " move speed -> " &
              formatFloat(s, ffDecimal, 2) &
              " (the FIRST of this session -- subsequent speed changes are " &
              "counted into the 10s rollup instead of logged one per line, " &
              "which was 12 lines/s and 36% of the host log)"
      else:
        inc gBnSpeedSince
        bnRollup(now)
    # A speed change does not cancel a destination, so fall through rather than
    # return: a bot told "go there, at half speed" gets both on this same tick.
  if not gBnReg[i].hasCmd:
    return
  if gBnReg[i].dead or now > gBnReg[i].cmdUntil:
    gBnReg[i].hasCmd = false
    return
  if now < gBnReg[i].nextIssue:
    return
  if not gBnReg[i].moved:
    # Not yet proven mobile. Wait rather than risk the managed throw.
    gBnReg[i].nextIssue = now + BnReissueMs
    return
  # Arrived? Stop re-issuing; SDistDestination is the mover's own answer.
  var ok = 0'i32
  let mover = cBnReadPtr(owner, cBnOffMover(), ok)
  if ok != 0'i32 and bnSanePtr(mover):
    let sd = cBnReadF32(mover, cBnOffSDist(), ok)
    if ok != 0'i32 and gBnReg[i].issues > 0'i32 and sd >= 0.0 and
       sd < BnArriveDist:
      gBnReg[i].hasCmd = false
      okLog "botnav: bot id=" & $int(gBnReg[i].id) &
            " arrived (SDistDestination " & formatFloat(sd, ffDecimal, 2) & ")"
      return
  gBnReg[i].nextIssue = now + BnReissueMs
  if gBnReg[i].sprint and gBnReg[i].issues == 0'i32:
    # `sprint` is honoured as "move at full speed", not as the game's own
    # `BotOwner::Sprint`. That method sits behind an il2cpp class-init guard and
    # feeds a debug callback, whereas SetTargetMoveSpeed is the two-instruction
    # `movss [Mover+0x15C], xmm1` we have byte-verified. Same visible effect for
    # a bot crossing a map, a fraction of the surface. Once per command, not per
    # re-issue -- the mover keeps the value.
    discard cBnSetSpeed(owner, 1.0)
  let st = cBnGoto(owner, gBnReg[i].cx, gBnReg[i].cy, gBnReg[i].cz,
                   gBnReg[i].reach, 1'i32, 0'i32)
  gBnReg[i].status = st
  gBnReg[i].issues = gBnReg[i].issues + 1'i32
  gBnIssued = gBnIssued + 1
  if gBnReg[i].issues == 1'i32 or (gBnReg[i].issues mod 20'i32) == 0'i32:
    let what = (if st == 0: "Complete" elif st == 1: "Partial"
                elif st == 2: "Invalid (no path to that point)"
                elif st == -1: "target unverified on this build"
                elif st == -2: "pre-flight refused (mover chain not ready)"
                else: "status " & $int(st))
    okLog "botnav: bot id=" & $int(gBnReg[i].id) & " GoToPoint(" &
          formatFloat(gBnReg[i].cx, ffDecimal, 2) & ", " &
          formatFloat(gBnReg[i].cy, ffDecimal, 2) & ", " &
          formatFloat(gBnReg[i].cz, ffDecimal, 2) &
          ") -> " & what & " (issue #" & $int(gBnReg[i].issues) & ")"
  if st == 2'i32:
    # The navmesh says there is no path. Saying it again 500 ms from now will
    # not change its mind; drop the command instead of spinning on it.
    gBnReg[i].hasCmd = false

proc bnMetres(v: float64): string =
  ## A coordinate as whole metres.
  ##
  ## Two reasons, and both are hard constraints rather than taste. First, the
  ## whole report path may be **191 characters** (`ReportMaxPath` -- the overlay's
  ## sync worker copies it into a 192-byte field and silently truncates beyond
  ## that), so every digit is paid for out of a very small budget. Second, Nim's
  ## `$` on a float can produce `1e-05` or seventeen significant digits, and the
  ## reader at the far end handles neither -- a coordinate that arrives as
  ## scientific notation is a bot in the wrong place, reported confidently.
  ##
  ## Metre precision is not a compromise for this: it is a bot's position on a
  ## map, read for deciding where to send it next.
  var a = v
  if a > 1000000.0: a = 1000000.0
  if a < -1000000.0: a = -1000000.0
  result = $int(a)

proc bnBuildCensus(now: int64) =
  ## Rebuild the compact registry string carried back to the backend/mod. Off the
  ## per-frame path (every `BnCensusMs`), so the allocation here is fine.
  ##
  ##   id,role,diff,alive,x,y,z,cmdStatus ! id,...
  ##
  ## ROTATES rather than dumping. The whole report path is capped at 191
  ## characters, which is nowhere near a full registry, so each census carries
  ## the bots that fit starting from where the last one stopped. Rotation rather
  ## than priority, for the same reason the mod-outcome rows rotate: every bot is
  ## reported within a few polls and no bot can be starved by a noisier
  ## neighbour. Nothing acknowledges anything, because each record is a STATE and
  ## repeating it is free.
  gBnCensusAt = now
  var s = ""
  var emitted = 0
  var k = 0
  while k < BnMaxBots:
    let i = (gBnCensusCursor + k) mod BnMaxBots
    inc k
    if not gBnReg[i].used:
      continue
    if now - gBnReg[i].lastSeen > BnStaleMs:
      continue
    let rec = $int(gBnReg[i].id) & "," & $int(gBnReg[i].role) & "," &
              $int(gBnReg[i].diff) & "," &
              (if gBnReg[i].dead: "0" else: "1") & "," &
              bnMetres(gBnReg[i].x) & "," & bnMetres(gBnReg[i].y) & "," &
              bnMetres(gBnReg[i].z) & "," & $int(gBnReg[i].status)
    let sep = (if emitted > 0: 1 else: 0)
    if s.len + sep + rec.len > BnCensusBudget:
      # Start the next census here, so this bot is the first one reported rather
      # than the one that is always cut off.
      gBnCensusCursor = i
      gBnCensus = s
      return
    if emitted > 0: s.add '!'
    s.add rec
    inc emitted
  gBnCensusCursor = 0
  gBnCensus = s

proc botNavCensus*(): string = gBnCensus
  ## The live registry, for the report that rides the existing poll. Read from
  ## the poll thread; a torn read is impossible in practice (whole-string
  ## assignment) and would cost at most one stale census.

proc botNavBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_botnav_body", cdecl.} =
  ## The ENTIRE per-bot tick, run under the VEH/SEH guard
  ## (`aowl_botnav_body_guarded`) so ANY fault -- including a guarded read of a
  ## valid-looking pointer whose slot is unmapped, or a fault inside the game's
  ## own GoToPoint -- is trapped and the bot's Update survives. `a` is the detour
  ## `regs`. RCX = the live BotOwner. Returns a non-nil sentinel on clean
  ## completion; the C guard returns nil if it faulted.
  ##
  ## There is exactly ONE guard, here, wrapping everything. No inner guard is
  ## armed anywhere below: `aowl_p_p_seh` is NOT re-entrant and a nested one
  ## would disarm this one on return.
  let regs = a
  if gBotNavOff:
    return cast[Il2CppPtr](1)
  gBotNavFires = gBotNavFires + 1
  let tid = int(cThreadId())
  if tid == int(gHostThreadId):
    # UpdateManual is a Unity-thread method; if it ever fires on ours, something
    # is not what we think it is and we touch nothing.
    return cast[Il2CppPtr](1)
  let ownerRaw = cRegsInt(regs, 0'i32)
  let owner = cast[Il2CppPtr](ownerRaw)
  if not bnSanePtr(owner):
    return cast[Il2CppPtr](1)

  let now = int64(cNowMs())
  let i = bnFind(cast[uint64](ownerRaw), now)
  if i < 0:
    if not gBnCapWarned:
      gBnCapWarned = true
      okLog "botnav: registry full at " & $BnMaxBots & " bots; further bots " &
            "are tracked but not commandable this raid"
    return cast[Il2CppPtr](1)

  bnRefresh(i, owner, now)

  # A new command set is picked up by ONE bot's tick (whichever ticks first) and
  # folded into every matching row at once, so this costs one int compare per
  # bot per frame in the steady state.
  if gBnGen != gBnApplied:
    bnApplyGeneration(now)

  bnService(i, owner, now)

  if now - gBnCensusAt > BnCensusMs:
    bnBuildCensus(now)

  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk -- the single guard for this feature. `aowl_p_p_seh`
# (abi/aowlspt_shim.h) arms a vectored exception handler + setjmp, calls the
# body, and returns nil instead of letting an access violation propagate. This
# is the same mechanism botai, botcap, botdiag and the settings probe use. A
# botnav fault must NEVER reach the game -- and unlike those, this one WRITES
# to game objects and CALLS into game code, so it is also the feature that most
# needs the self-disable below.
{.emit: """
extern void* aowl_botnav_body(void* a);
static void* aowl_botnav_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_botnav_body, a);
}
""".}
proc cBotNavBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_botnav_body_guarded", nodecl.}

proc botNavUpdateFired(regs: Il2CppPtr) =
  ## Fired from the kind=15 detour on `EFT.BotOwner::UpdateManual`, on the Unity
  ## main thread, once per live bot per frame. Runs the whole tick under the
  ## VEH/SEH guard; if anything faults we count it, log it, and after
  ## `BnMaxFaults` we switch the feature off for the rest of the run rather than
  ## keep poking a game that has told us twice it does not like this.
  if gBotNavOff:
    return
  if cBotNavBodyGuarded(regs) == nil:
    gBotNavFaults = gBotNavFaults + 1
    okLog "botnav: fault caught (" & $gBotNavFaults & "/" & $BnMaxFaults &
          "), skipped -- the VEH guard kept the bot's Update alive"
    if gBotNavFaults >= BnMaxFaults:
      gBotNavOff = true
      warn "botnav: self-disabled after " & $BnMaxFaults & " faults; no " &
           "further bot registry or nav commands this run"

proc bindBotNav(verbose: bool): bool =
  ## Installs the kind=15 detour on `EFT.BotOwner::UpdateManual` from the
  ## verified static target in `aowlspt_botnav.h`. Opt-in (`botNav`); binds
  ## nothing on a build whose prologue does not match. BotOwners exist only
  ## inside a raid, so the detour installs now and simply never fires until bots
  ## are ticking.
  if gBotNavSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let count = cBotNavTargetCount()
  for i in 0 ..< int(count):
    let fn = cBotNavTargetAt(int32(i))
    if fn == nil:
      if verbose:
        info "botnav target " & $i & " did not verify on this build"
      continue
    let spec = readCString(cBotNavTargetName(int32(i)))
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose, 15'i32):
      if not gBnCallsChecked:
        gBnCallsChecked = true
        if cBotNavCallsOk() == 0'i32:
          warn "botnav: the registry will run, but EFT.BotOwner::GoToPoint / " &
               "StopMove / SetTargetMoveSpeed did NOT byte-verify on this " &
               "build -- nav COMMANDS are disabled; the census still works"
        else:
          okLog "botnav: GoToPoint @0x81CB40, StopMove @0x81C970 and " &
                "SetTargetMoveSpeed @0x81C9C0 all byte-verified"
      okLog "botnav (bot navigation API) armed on " & spec &
            "; enter a raid to populate the bot registry and accept nav commands"
      return true
  result = false
