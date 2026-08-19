## The lesson — the API a mod on any host needs, in the order it needs it.
##
##     aowl run examples/lesson                    the simulator: no game, no server
##     aowl build-mod examples/lesson              just compile it
##
##     :: and against the stand-in IL2CPP runtime, in a stage of its own
##     mkdir installer\build\lessonstage\mods\lesson
##     copy host\Aowlspt.Host.Il2Cpp\bin\aowlspt-host-il2cpp.dll installer\build\lessonstage
##     copy examples\lesson\bin\lesson.dll installer\build\lessonstage\mods\lesson
##     copy examples\lesson\config.json installer\build\lessonstage\mods\lesson
##     installer\build\hostharness.exe installer\build\lessonstage ^
##         --runtime tests\mockil2cpp\GameAssembly.dll --seconds 8
##
## A stage of its own, and not `installer\build\hoststage`: the detour engine
## allows **one hook per method** (the slot pool is 256 and is not the
## constraint here), and `hoststage`
## already has `highlevel` in it hooking most of the same stand-in methods. Two
## mods competing for one method is a refusal in whichever arms second, and the
## refusal would look like a bug in the mod rather than a collision in the
## stage.
##
## ---------------------------------------------------------------------------
## THIS FILE AND `examples/highlevel` ARE NOT THE SAME KIND OF THING
## ---------------------------------------------------------------------------
##
## `examples/highlevel` is the client host's **regression test**. A run of the
## gate's stage makes twenty-four assertions in `tools/hostharness.nim`; fifteen
## of them are greps for exact strings that file alone prints — `field agrees
## with get_`, `an enum parameter binds on the fast path`, `the scheduler reused
## its slots`, `everyMain fired `, `a static field write landed` — and three
## more (`Add(17, 25) = 42`, the Unity version, a patch firing) it shares with
## `examples/clientprobe`. Every line it prints is load-bearing
## for somebody else's red gate, and it is organised around covering the host
## rather than around teaching anyone. Read it to find out what the host is
## asserted to do. Do not read it to find out how to write a mod, and do not
## edit it without moving those assertions with you.
##
## **This file is the lesson.** Nothing greps it. It is ordered from what every
## mod does to what only a fast mod does, each section says why the API is
## shaped the way it is and what failure that shape prevents, and every number
## it **prints** it measured in this process first. (The figures in the comments
## are the ones from `docs/PERF.md`, for orientation while you read; the ones in
## the log are this machine's.)
##
## ---------------------------------------------------------------------------
## THE ORDER, AND WHY IT IS THIS ORDER
## ---------------------------------------------------------------------------
##
## It said "every part of the current API" until 2026-08-19, and three things
## it never covered are worth naming rather than leaving a reader to notice the
## gap: **routes** and the **database** (`serve`, `servePrefix`, `dbRead`,
## `dbWrite` — `examples/gameserver` and `examples/backend`), and
## **`notifyPush`**, the revision-5 push to a session, which section 1 asks
## about and no example anywhere demonstrates. `mods/pathtotarkov` and
## `mods/tarkov` are the two working uses of it.
##
##   1. Identity, and asking what the host can do    — every mod, first
##   2. Config                                       — every mod
##   3. The store                                    — every mod that remembers
##   4. Events                                       — talking to other mods
##   5. Timers and the main thread                   — doing something later,
##                                                     and doing it every frame
##   6. The per-mod lock                             — the moment two threads exist
##   7. Hot reload                                   — surviving a rebuild
##  ---- everything above this line runs on the server, the client and the
##       simulator. Everything below it needs a game. ----
##   8. Types, calls, live objects, fields, enums    — the boxed path
##   9. Hooks, as JSON                               — hook, hookArgs, hookReturn
##  10. `this` as an address                         — the bridge between halves
##  11. Hooks, typed                                 — hookTyped, hookReturnTyped
##  12. The fast path                                — bindMethod, bindOnObject,
##                                                     bindField, bindStaticField,
##                                                     bindRaw
##  13. The measurements                             — printed, not claimed
##
## Sections 8 to 13 need an IL2CPP runtime in the process. Under `aowl run` there
## is not one, and this mod **says so, per facility, at run time** rather than
## going quiet. A capability that is silently absent is indistinguishable from a
## capability that is broken.
##
## ---------------------------------------------------------------------------
## THE ONE HABIT WORTH TAKING AWAY
## ---------------------------------------------------------------------------
##
## **Bind once, resolve by name, refuse cleanly with a reason, and ask the host
## rather than assuming a revision.** Every arm site below has the same four
## lines in the same order:
##
##     if not <capability>Ready():        -> record "refused: <why, with the cost>"
##     if <the good path> == Ok:          -> record "armed on the fast path"
##     elif <the fallback> == Ok:         -> record "armed on the slow path, at N ns"
##     else:                              -> record "refused: " & lastError()
##
## and the record always names **which path armed**, because the two differ by
## roughly a hundredfold and the word "armed" on its own would hide that.
##
## Nothing here has ever run against BSG's client.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/json
import aowlspt/server
import aowlspt/sync
import aowlspt/il2cpp
import aowlspt/fast

const ModName = "lesson"

# Targets, named once. A typo in a target string is a hook that never fires and
# never says why, so they are constants rather than repeated literals.
const TyCtx    = "EFT.MovementContext"
const TyPlayer = "EFT.Player"

# ---------------------------------------------------------------------------
# Logging shape
# ---------------------------------------------------------------------------
#
# Every line this mod prints starts with `lesson  ` and then a section number,
# so a reader can line the log up against the file. `say` is `info`, `good` is
# `success`, `bad` is `warn`. There is no `error` anywhere in here: nothing this
# mod does is something the person running it must act on.

proc say(section: int; msg: string) =
  info ModName & "  " & $section & ". " & msg

proc good(section: int; msg: string) =
  success ModName & "  " & $section & ". " & msg

proc bad(section: int; msg: string) =
  warn ModName & "  " & $section & ". " & msg

proc note(msg: string) =
  ## A continuation of the line above it. Four spaces, the house indent for a
  ## parenthetical under a report line.
  info ModName & "      " & msg

proc padLeft(s: string; n: int): string =
  result = ""
  var i = s.len
  while i < n:
    result.add ' '
    inc i
  result.add s

proc padRight(s: string; n: int): string =
  result = s
  while result.len < n:
    result.add ' '

# ---------------------------------------------------------------------------
# 1. Identity, and asking the host what it can do
# ---------------------------------------------------------------------------
#
# The first thing a mod should do is find out where it is, and the second is
# find out what that place can do. Both matter more here than in a managed
# plugin system, because the same compiled `.dll` loads into three hosts that
# genuinely differ: the backend has no game to reflect into, the client host has
# no database to read, and the simulator has neither.
#
# Every capability test below is a **size test** against the ABI revision that
# capability appeared at — `storeReady` tests `HostApiSizeRev2`, `livePointersReady`
# tests Rev3, `typedPatchesReady` tests Rev4, `notifyReady` tests Rev5. That is
# not an implementation detail leaking out. nimony will not `cast` a proc field
# to a pointer to compare it against null, so there is no null check available;
# `size` says how much of the struct the host filled, and a host that reports a
# size has filled everything up to it. Testing against `sizeof(HostApi)` instead
# is right exactly once — the day the struct next grows, every older host starts
# answering "no store" when it has one.
#
# The tests therefore mean "there is a function here that will answer", not
# "this works". On the backend and on `aowlspt-sim` the revision-3 and
# revision-4 entries are filled with the refusal they already owed, precisely so
# that one integer can say "the fourth and not the fifth". So **check the status
# of the call too**, which is what every arm site below does.

var gSideName = ""
var gCanStore = false
var gCanPointers = false
var gCanTyped = false
var gCanNotify = false

proc sideName(): string =
  case ord(side())
  of 1: result = "server"
  of 2: result = "client"
  of 3: result = "simulator"
  else: result = "unknown"

proc reportEnvironment() =
  gSideName = sideName()
  gCanStore = storeReady()
  gCanPointers = livePointersReady()
  gCanTyped = typedPatchesReady()
  gCanNotify = notifyReady()

  good(1, "loaded into " & hostName() & " " & hostVersion() &
          " on the " & gSideName & " side")
  note "mod directory   " & modDir()
  note "data directory  " & dataDir()
  let spt = sptVersion()
  let game = gameVersion()
  note "SPT             " & (if spt.len > 0: spt else: "(not reported here)")
  note "game            " & (if game.len > 0: game else: "(not reported here)")
  note "host clock      " & $nowMs() & " ms since the host started"

  # The two numbers side by side. They are different questions: the first is
  # what this host filled in, the second is what this mod was compiled against.
  # A mod built against a newer ABI than the host it lands in needs to find that
  # out here, from a number, rather than from a call through a null pointer.
  note "HostApi         " & $hostApiSize() & " bytes filled by the host, " &
       $expectedApiSize() & " bytes in the header this mod compiled against"

  say(1, "capabilities, each a size test against the revision it appeared at:")
  note "rev 2  store            " & (if gCanStore: "yes" else: "no")
  note "rev 3  live pointers    " & (if gCanPointers: "yes" else: "no") &
       (if gCanPointers: "" else: "  (so `this` can only be reached through a boxed call)")
  note "rev 4  typed patches    " & (if gCanTyped: "yes" else: "no") &
       (if gCanTyped: "" else: "  (so every hook below arms as JSON)")
  note "rev 5  notifications    " & (if gCanNotify: "yes" else: "no") &
       (if gCanNotify: "" else: "  (backend only: it needs a websocket)")

# ---------------------------------------------------------------------------
# 2. Config
# ---------------------------------------------------------------------------
#
# `config.json` next to the library, read through the host rather than off the
# disk: the host knows where the mod's directory is and a mod that opens the
# file itself is a mod that breaks the first time somebody stages it somewhere
# else. An empty key returns the whole document.
#
# It is read once here and kept, rather than re-read per use. `configGet` is a
# host round trip and a buffer copy, which is nothing at load and is a frame tax
# in `onUpdate`.

var gGreeting = "operator"
var gTiltCeiling = 4.0
var gSamples = 20000

proc readConfig() =
  var whole = ""
  if configGet("", whole) != Ok or whole.len == 0:
    say(2, "no config.json here, so the built-in defaults stand " &
           "(greeting=" & gGreeting & ", tiltCeiling=" & $gTiltCeiling & ")")
    return
  # `aowlspt/json` scans; it does not build a tree. A `JsonRef` is a pair of
  # offsets into text somebody else owns, so each `field` is one walk and no
  # allocation — which is why reading four keys out of one document costs four
  # walks rather than a parse.
  gGreeting = asText(field(whole, "greeting"), gGreeting)
  gTiltCeiling = asFloat(field(whole, "tiltCeiling"), gTiltCeiling)
  gSamples = asInt(field(whole, "measureSamples"), gSamples)
  if gSamples < 100:
    gSamples = 100
  good(2, "config read: greeting=" & gGreeting & " tiltCeiling=" &
          $gTiltCeiling & " measureSamples=" & $gSamples)
  # `configSet` exists and is refused by every host that treats `config.json` as
  # the person's file rather than the mod's. Asked for anyway, so the log says
  # which kind of host this is instead of the mod assuming.
  if configSet("lesson.probe", "1") == Ok:
    note "this host allows a mod to write its own config back"
  else:
    note "this host refuses configSet (" & lastError() &
         "), which is the usual answer: config.json is the operator's file"

# ---------------------------------------------------------------------------
# 3. The store
# ---------------------------------------------------------------------------
#
# `save` / `load` / `savedKeys`, one file per key under `store/<your-guid>/`.
# It is the only thing a mod owns that cannot be rebuilt, so the host writes
# through a temporary and renames over the key: a reader sees the whole previous
# value or the whole new one, never a mixture, and that holds against the
# process being killed mid-write.
#
# `dbGet`/`dbPatch` is the *shared* game database and is the wrong place for a
# mod's save state — patching `templates.items` to remember a player's progress
# puts one mod's state where every other mod reads templates.
#
# The one rule with teeth is `Stored.missing`. A mod that creates a fresh state
# on a failed `load` is right on a first run and catastrophically wrong when the
# value is on disk and unreadable: it writes a new one over a file the store's
# own history would very likely have recovered. So: check `missing` before
# creating, and refuse loudly when it is false.
#
# The simulator has a store now — same `host/common/modstore.nim` the backend
# uses, rooted under `%TEMP%\aowlspt-sim\<mod>` — so this section runs under
# `aowl run`, and the run count below goes up every time you run it.

var gRuns = 0

proc useStore() =
  if not gCanStore:
    bad(3, "this host is older than ABI revision 2 and has no store, so " &
           "nothing this mod learns survives the run")
    return

  let previous = load("lesson.runs")
  if previous.ok:
    gRuns = asInt(field(previous.raw, "runs"), 0)
  elif previous.missing:
    # The ordinary first run. Nothing is wrong.
    say(3, "no run count stored yet, so this is the first run against this host")
  else:
    # The dangerous case, and the reason `missing` exists as a separate field.
    bad(3, "the run count is stored and could not be read (" & previous.error &
           "). NOT creating a new one: overwriting an unreadable value is how " &
           "a recoverable file becomes an unrecoverable one")
    return

  inc gRuns
  discard save("lesson.runs", "{\"runs\":" & $gRuns & "}")
  # A second key, so `savedKeys` has a prefix worth listing.
  discard save("lesson.host", "{\"host\":\"" & hostName() & "\"}")
  good(3, "run " & $gRuns & " against this host; store keys under \"lesson.\":")
  for key in savedKeys("lesson."):
    note "  " & key & " = " & load(key).raw
  note "an invalid key is refused rather than mangled into a filename: " &
       "save(\"../escape\") -> " &
       (if save("../escape", "{}") == Ok: "accepted (!)" else: "refused")

# ---------------------------------------------------------------------------
# 4. Events
# ---------------------------------------------------------------------------
#
# The only channel that exists on every host, which is why the mod manager's
# whole control protocol is built on it rather than on new ABI functions.
#
# Delivery is **synchronous**, in subscription order, to everyone *but* the
# emitter. Not receiving your own event is deliberate: a mod that owns an event
# usually subscribes to it too, and delivering it back is a loop nobody wrote.
# Synchronous is also why a host queues an unload request instead of performing
# it inside the emit — the stack at that moment runs through the mod being
# unloaded, and `FreeLibrary` there returns into unmapped memory.
#
# Under `aowl run` there is no second mod to talk to, so use
# `aowlspt-sim examples/lesson --emit lesson.ping,{"n":1}` to see the handler
# run.

var gEventsHeard = 0

proc onPing(payload: string): string =
  withModLock:
    inc gEventsHeard
  good(4, "heard lesson.ping with payload " & payload)
  "{\"pong\":true}"

proc onAnyUnload(payload: string): string =
  ## The host announces a pending unload *before* it performs it, which is the
  ## only moment a mod has a whole tick of running host left to put something
  ## back. Subscribed to rather than waited for.
  let guid = asText(field(payload, "guid"), "")
  if guid.len > 0 and guid != "aowl.lesson":
    return ""
  say(4, "an unload of this mod has been requested; anything that must be " &
         "put back should be put back now, not in onUnload")
  ""

proc armEvents() =
  discard on("lesson.ping", onPing)
  discard on("aowlspt.host.mods.unload", onAnyUnload)
  # Emitting our own event proves the call works and delivers to nobody here,
  # which is the rule rather than a failure.
  let st = emit("lesson.loaded", "{\"version\":\"1.0.0\"}")
  good(4, "subscribed to lesson.ping and to the host's unload announcement; " &
          "emit(lesson.loaded) returned " & $ord(st) &
          " and was delivered to every mod but this one")

# ---------------------------------------------------------------------------
# 5. Timers, and the host's main thread
# ---------------------------------------------------------------------------
#
# `after(ms)` once, `every(ms)` repeatedly, `onMainThread()` as soon as
# possible. All three run on the host's scheduler.
#
# `every` re-arms itself with the same cookie rather than registering a fresh
# handler per firing; the alternative leaks one table entry per tick, which only
# shows up in a server left running for a week. The interval is between
# *firings*, not between starts, so a handler slower than its interval falls
# behind rather than overlapping itself.
#
# **A one-shot gives its slot back once it has fired; a repeat holds exactly
# one for the life of the chain.** `after` and `onMainThread` release theirs in
# `tickTrampoline`; `every` and `everyMain` re-arm on the same cookie and the
# same slot, which is the point made at length under `everyMain` below. This
# said "all three give their slot back", which was right about the two one-shots
# and wrong about `every`, until 2026-08-19.
#
# The one-shot half is worth proving rather than believing, because it used to
# be false: `after` and `onMainThread` took a slot per call and never returned
# it, so a mod queueing work every frame — the documented way to reach Unity's
# thread — grew the table without bound. `scheduledSlots()` reports its size,
# live plus free, and the number below should settle at roughly the number of
# callbacks outstanding at once rather than at the number ever scheduled.
#
# On the client, `onMainThread` gets Unity's thread only if the host managed to
# detour a per-frame method. Ask outright with `call("aowlspt.host::main_thread")`
# rather than assuming; a callback that touches a Unity object from the host's
# own thread is a crash.
#
# ## `everyMain` — a repeat *on the game's thread*
#
# `everyMain(handler)` runs the handler once per drain, on the thread the host
# drains its main-thread queue on — which on a host whose drain is per-frame is
# once per frame. `stopMainRepeats()` stops every chain this mod started and
# says how many it stopped.
#
# **It is not `every(16, ...)`, and the difference is not the one that is
# written down in most places.** The version in circulation was that "`every`
# repeats on the host's thread; `onMainThread` reaches Unity's and does not
# repeat". `docs/BACKLOG.md` and `mods/perf/README.md` both carried it and both
# now name it as wrong, so this paragraph no longer points at a live example of
# it — it is written down here because it will be repeated again. On the
# IL2CPP client host the first half is false: `hostSchedule` and
# `hostInvokeMain` share one queue and one thread there, so a short `every` does
# land on the game's thread. Two real differences remain, and they are the
# reasons to use this instead:
#
#  * **A deadline is not a frame.** `every(16, ...)` fires when 16 ms have
#    elapsed. At 144 fps that is every third frame; at 30 fps it is once a frame
#    and drifting. Neither is "once per frame", which is what a mod sampling
#    frame times or writing a value the game reads each frame actually needs.
#    `everyMain` fires once per drain, so it tracks the frame rather than the
#    clock.
#  * **The ABI only ever promised the main thread for `invoke_main`.** That the
#    two queues coincide is one host's implementation detail, and the backend's
#    `every` already does not: it runs on the backend's own timer. A mod that
#    reaches Unity through `every` is relying on something nothing owes it.
#
# **One slot, not one per firing.** The re-arm reuses the same cookie and the
# same scheduler slot, exactly as `every` does. The hand-written version of this
# chain — a one-shot that calls `onMainThread` again before it returns — claims
# a slot per firing and gives it back at the end of the same firing. That is
# correct, and it churns the pool, and it makes `scheduledSlots()` unable to
# tell a working chain from a leaking one. The number below is taken *inside* a
# firing, so it is the table size while the chain is live.
#
# **The stop is deferred by one firing, on purpose.** `stopMainRepeats` clears
# the marker; the firing already queued runs one more time and then releases its
# slot instead of re-arming. That is not a limitation being apologised for: the
# chain is queued on the game's thread and the stop is usually called from
# another one, and yanking a slot out from under a callback that is about to run
# is the one way a stop could turn into a crash. So "one more firing after the
# stop" is the correct answer, and this file checks for it rather than for zero.
#
# **`currentThreadId()`** (from `aowlspt/fast`) is how a mod checks *where* a
# callback ran. It is the only way to make "this ran on the game's thread" a
# claim rather than a hope: touching a Unity object from a worker does not fail,
# it works until the frame it does not, and the crash is nowhere near the call.

var gSlotsAtArm = 0
var gMainQueued = 0
var gTimerFires = 0
var gAfterFired = false
var gMainThreadFired = false

proc onceLater(payload: string): string =
  gAfterFired = true
  ""

proc repeatedly(payload: string): string =
  withModLock:
    inc gTimerFires
  ""

proc onMain(payload: string): string =
  gMainThreadFired = true
  ""

proc queueOneMore() =
  ## Called from `onUpdate`, every tick. This is the documented way to reach
  ## Unity's thread, and it is exactly the pattern that used to leak: one slot
  ## per call, never returned. `reportSchedule` prints the table size after all
  ## of these, and the number that matters is that it did not grow with the
  ## count.
  inc gMainQueued
  discard onMainThread(onMain)

# --- everyMain --------------------------------------------------------------

var gLoadThread = 0'i64      ## the thread `onLoad` ran on
var gRepeatArmed = false
var gRepeatFires = 0
var gRepeatThread = 0'i64    ## the thread the chain's first firing ran on
var gRepeatOtherThreads = 0  ## firings that ran on a *different* thread
var gSlotsInFiring = -1      ## the table size, sampled inside a firing
var gStopSaid = -1           ## what stopMainRepeats() answered
var gFiresAtStop = -1
var gTickAtStop = -1

proc perFrame(payload: string): string =
  ## One firing of `everyMain`, on the game's thread.
  ##
  ## Everything here is under the lock because this thread is not the one
  ## `onUpdate` runs on — which is the whole reason the chain exists, and the
  ## reason section 6 exists.
  let t = currentThreadId()
  withModLock:
    inc gRepeatFires
    if gRepeatThread == 0'i64:
      gRepeatThread = t
    elif t != gRepeatThread:
      inc gRepeatOtherThreads
    # Sampled *inside* the firing, so it is the table size while the chain is
    # live rather than after it has released. A chain that claimed a slot per
    # firing would push this up with the firing count.
    gSlotsInFiring = scheduledSlots()
  ""

proc armSchedule() =
  gLoadThread = currentThreadId()
  gSlotsAtArm = scheduledSlots()
  discard after(1, onceLater)
  discard every(500, repeatedly)
  discard onMainThread(onMain)
  say(5, "scheduler had " & $gSlotsAtArm & " slots before arming; armed " &
         "after(1ms), every(500ms) and one onMainThread callback")

  # And the per-frame chain. The status is the host's own answer to the first
  # queue attempt, so a host with no main thread to reach says so here rather
  # than leaving a handler that never fires.
  let st = everyMain(perFrame)
  gRepeatArmed = st == Ok
  if gRepeatArmed:
    note "everyMain armed; onLoad ran on thread " & $gLoadThread &
         ", and section 5's report says which thread the chain fired on"
  else:
    note "everyMain was refused by this host (" & lastError() & "), which is " &
         "the honest answer on a host with no main-thread queue -- a server " &
         "mod gets this and should not pretend otherwise"

  var mt = ""
  if call("aowlspt.host::main_thread", "[]", mt) == Ok:
    note "main_thread says " & mt
  else:
    note "this host does not answer aowlspt.host::main_thread (" &
         lastError() & "), so onMainThread means the host's own thread"

proc stopRepeats(tick: int) =
  ## Called once, a few ticks in, so that the report below has a gap between the
  ## stop and the reading — which is what makes "deferred by exactly one
  ## firing" a measurement rather than a claim.
  if not gRepeatArmed or gStopSaid >= 0:
    return
  withModLock:
    gFiresAtStop = gRepeatFires
  gTickAtStop = tick
  gStopSaid = stopMainRepeats()

proc reportSchedule() =
  let now = scheduledSlots()
  good(5, "after() fired: " & $gAfterFired & ", onMainThread fired: " &
          $gMainThreadFired & ", every(500ms) fired " & $gTimerFires & " times")
  note "scheduler slots " & $gSlotsAtArm & " -> " & $now & " after " &
       $gMainQueued & " onMainThread call(s) on top of the three armed at " &
       "load. The table holds live and free slots together, so the number to " &
       "watch is that it settled rather than tracking the count: one slot per " &
       "call never returned is the leak this reports on."

  if not gRepeatArmed:
    note "everyMain was not armed on this host, so nothing below it is claimed"
    return

  var fires = 0
  var other = 0
  var slots = -1
  var atStop = -1
  withModLock:
    fires = gRepeatFires
    other = gRepeatOtherThreads
    slots = gSlotsInFiring
    atStop = gFiresAtStop

  if fires == 0:
    note "everyMain was accepted and never fired. On this host the drain has " &
         "nothing driving it -- which is a statement about the host, not " &
         "about the chain, and is why the count is printed rather than assumed"
    return

  good(5, "everyMain fired " & $fires & " times, all on thread " &
          $gRepeatThread & " (" & $other & " firing(s) on any other thread), " &
          "while onLoad ran on " & $gLoadThread)
  note "that comparison is the whole point of currentThreadId(): 'it ran' is " &
       "not the claim, 'it ran where a Unity object may be touched' is, and " &
       "one thread id either side of the handoff is the only thing that says so"
  note "the scheduler held " & $slots & " slot(s) in total during a firing, " &
       "against " & $fires & " firings -- one slot for the chain, re-armed " &
       "with the same cookie, rather than one claimed and released per frame"

  if gStopSaid >= 0:
    note "stopMainRepeats() stopped " & $gStopSaid & " chain(s) at tick " &
         $gTickAtStop & ", after " & $atStop & " firing(s); the count is now " &
         $fires & ", so " & $(fires - atStop) & " further firing(s) got " &
         "through. One is the correct answer and zero would be the alarming " &
         "one: the stop clears the marker and lets the already-queued firing " &
         "run, because taking the slot back from a callback about to run on " &
         "another thread is the one way a stop could crash"

# ---------------------------------------------------------------------------
# 6. The per-mod lock
# ---------------------------------------------------------------------------
#
# Every counter this file increments from a callback is incremented under
# `withModLock`, and the reason is not hypothetical. A mod's globals are not
# touched by one thread: the backend serves requests on sixteen workers, so two
# route handlers in the same mod run at once; the client host calls `on_update`
# on its own thread while a detour fires on the game's; a timer or an event
# subscriber may arrive on either.
#
# It costs no ABI revision and no host support. `abi/aowlspt_lock.h` is a
# one-time-initialised `CRITICAL_SECTION` whose contents are `static`, and
# nimony emits one translation unit per module — so the lock belongs to *this
# module in this mod's library*. Every mod that links the library gets exactly
# one of its own and two mods can never contend with each other. It is not the
# host's lock: the host's guards the host's lists.
#
# Hold it for the shortest span that keeps the state consistent, and never
# across a call that can block. It is not reentrant — taking it twice on one
# thread is a deadlock by contract, even though Windows' `CRITICAL_SECTION`
# happens to be recursive today.
#
# **Not inside a hook handler on the per-frame path.** A lock in a method the
# game calls forty times a frame is a contention point in the game's own thread;
# the counters in sections 9 to 12 below are therefore plain, and each one is
# written by exactly one thread.

# ---------------------------------------------------------------------------
# 7. Hot reload
# ---------------------------------------------------------------------------
#
# `stateSave` runs just before the library is freed and `stateLoad` on the next
# incarnation, so rebuilding a mod mid-session does not visibly reset it. The
# `mfHotReloadable` flag in `exportMod` is what tells the host both exist.
#
# Try it: `aowlspt-sim examples/lesson --watch --ticks 0`, then rebuild the mod
# in another window. The run count below is carried across, and it does not go
# up — a reload is not a new run.
#
# The state is a string, and it crosses a `FreeLibrary`. Keep it small, keep it
# JSON, and do not put a pointer, a handle or a binding in it: every one of
# those names something in the address space that is about to stop existing.

proc stateSave(): string =
  "{\"runs\":" & $gRuns & ",\"events\":" & $gEventsHeard & "}"

proc stateLoad(state: string): Status =
  gRuns = asInt(field(state, "runs"), gRuns)
  gEventsHeard = asInt(field(state, "events"), gEventsHeard)
  say(7, "reloaded, carrying run=" & $gRuns & " events=" & $gEventsHeard &
         " across the FreeLibrary")
  Ok

# ===========================================================================
# Everything below here needs a game in the process.
# ===========================================================================

# Types are named at the top of the file and resolved on first use, and that
# split is the whole reason `GameType` exists. When a mod loads, the process has
# an IL2CPP runtime but the game has not finished loading its own assemblies, so
# resolving `EFT.Player` at load time is a false negative rather than an answer.
#
# `gameType` is a **template**, not a proc, and that is load-bearing: in a nimony
# `--app:lib` build a global initialised by a *call* is never initialised —
# literal initialisers are folded at compile time, anything needing runtime
# evaluation is skipped, and the global is left zeroed. A template expands to an
# object literal at the declaration, which does get folded. If you write a helper
# that hands back a `GameType`, make it a template too, or `resolveNow` will warn
# that a `GameType` has no name, which is what that warning means.
#
# **Spell the name as a literal, not as a `const`.** `gameType(TyPlayer)` looks
# identical and is not: the folding that saves a global initialiser in an
# `--app:lib` build happens on a literal, and a named constant does not survive
# it. The global is left zeroed, `resolveNow` warns that "a GameType has no
# name", and that warning means exactly this mistake. The `const`s above are for
# hook targets, which are ordinary runtime strings.
var Player = gameType("EFT.Player")
var Context = gameType("EFT.MovementContext")
var Application = gameType("UnityEngine.Application")
var world = whenReady("EFT.MovementContext")

var gTicks = 0
var gTypeSeen = false      ## a type resolved -- which is *not* proof of a game
var gRuntimeOk = false     ## openIl2Cpp() found a runtime to bind
var gArmedHooks = false
var gReported = false

# The mod's own binding of the runtime. A mod DLL is in the host's process, so
# `openIl2Cpp()` binds the already-loaded `GameAssembly.dll` directly and the
# host is not on this path at all. Declared bare and assigned from inside a
# proc, which is the mirror image of the `gameType` rule: `Binding` and `Il2Cpp`
# cannot be templates, so the discipline moves to the assignment.
var rt: Il2Cpp
var rtOpen = false

proc openRuntime(): bool =
  if rtOpen:
    return true
  rt = openIl2Cpp()
  if not rt.loaded:
    return false
  rtOpen = true
  result = true

# ---------------------------------------------------------------------------
# 8. Types, calls, live objects, fields and enums — the boxed path
# ---------------------------------------------------------------------------
#
# `resolve` a type, `call` a member by name with JSON arguments, read JSON back.
# About a microsecond a call, and that microsecond buys the generality: this is
# how a mod reaches a corner of the game the ABI has never grown a door for,
# with a target it may have read out of its own config file.
#
# Arguments are bound to the method's **declared** parameter types, read off the
# method itself rather than guessed from the shape of the value passed. IL2CPP
# will not check: hand `il2cpp_runtime_invoke` an object pointer where it wanted
# a pointer-to-int and it reads the object header as an integer, with no error
# anywhere. A mismatch is refused instead.

proc boxedPath() =
  say(8, "the boxed path — call by name, arguments as JSON")

  # A static method with two integer arguments. No JSON, no quoting, no
  # argument array at the call site.
  let sum = Player.invoke("Add", 17, 25)
  if sum.ok:
    note "Player.invoke(\"Add\", 17, 25) -> " & $sum.asInt()
  else:
    note "Add refused: " & sum.error

  # A string argument, from config, so the round trip is visible.
  let greeted = Player.invoke("Greet", gGreeting)
  note "Player.invoke(\"Greet\", \"" & gGreeting & "\") -> " &
       (if greeted.ok: greeted.asText() else: "refused")

  # A property getter. `get("X")` is `get_X`, `set("X", v)` is `set_X`.
  let unity = Application.get("unityVersion")
  note "Application.get(\"unityVersion\") -> " &
       (if unity.ok: unity.asText() else: "refused")

  # A `CallResult` is a record rather than a bare string on purpose. A failed
  # call would otherwise hand back "", which is a perfectly plausible value for
  # plenty of methods, and the failure would read as data.
  let nope = Player.invoke("ThisMethodDoesNotExist")
  note "a call that cannot work fails rather than answering \"\": ok=" &
       $nope.ok & " error=" & nope.error

  # --- live objects ---------------------------------------------------------
  #
  # A `GameType` is the static half of the game. Almost everything a mod wants
  # is on the other half: *this* context's tilt, *this* player's health.
  #
  # `instanceOf`, `child` and any call returning a reference type hand back a
  # `GameObj`, which holds an IL2CPP GC handle rather than a pointer. Keeping
  # one across frames is therefore safe — the collector moves objects, and a
  # raw address that was right last frame is not right this one. The price is
  # `release()`: a handle held for the session pins its object, which is a leak
  # rather than a crash, and that is the right way round for a mistake to fall.
  let ctx = Context.instanceOf()
  if not ctx.ok:
    note "no live MovementContext yet (get_Instance answered null), which is " &
         "an ordinary answer rather than a failure"
    return

  # `alive()` asks the object for its type, which is an ordinary call: a runtime
  # that does not implement `GetType` answers false for an object that is
  # plainly there. It is a check against a *collected* object, not a health
  # check, and it costs a boxed call -- so ask it before a long chain, not per
  # frame.
  note "a live " & ctx.typeName & ", alive() says " & $ctx.alive() &
       " (that is a GetType call, so a runtime without one answers false)"

  # --- fields ---------------------------------------------------------------
  #
  # `get`/`set` reach a C# **property**, which compiles to `get_X`/`set_X`. A
  # **field** has no method behind it and is unreachable that way — and a great
  # deal of what a mod wants on this game is a field, often a private one.
  # Underneath, `field` is an ordinary `call` with an `@` in front of the member
  # name: `EFT.MovementContext::@Tilt`. That spelling is the escape hatch if you
  # are building the target string yourself.
  #
  # Values are read and written by the field's declared type, so writing a float
  # into an int field is refused rather than reinterpreted. The bytes for `1`
  # and `1.0` are different bytes and nothing downstream would notice until the
  # game did.
  let tilt = ctx.field("Tilt")
  note "ctx.field(\"Tilt\") -> " & (if tilt.ok: $tilt.asFloat() else: tilt.error)
  discard ctx.setField("Tilt", v(1.0))
  note "after setField(\"Tilt\", 1.0) it reads " & $ctx.field("Tilt").asFloat()

  # --- enums ----------------------------------------------------------------
  #
  # **Enums are plain numbers in both directions.** Most of what this game's
  # methods take is an enum — every state, condition, damage kind and body part
  # — and an enum is declared by its own name, so it matches none of the
  # primitive branches. It is bound from a number at the payload width the
  # runtime reports for it, rather than at an assumed four bytes, because the
  # object header the runtime folds into that width is *measured* (against
  # `System.Int32`, whose payload is four bytes by definition) rather than
  # assumed to be sixteen.
  #
  # Before that: an enum argument was refused outright, and an enum return came
  # back as `{"handle":6,"type":"System.Int32"}` — so `asInt()` answered 0 with
  # `ok` true, a wrong value that reads like a right one, and the handle behind
  # it was never released.
  let applied = ctx.invoke("ApplyCondition", v(2))
  if applied.ok:
    let cond = ctx.get("Condition")
    note "ApplyCondition(2) accepted a plain number, and get_Condition came " &
         "back as " & cond.raw & " rather than as a handle"
  else:
    note "ApplyCondition refused: " & applied.error

  # A value type wider than eight bytes is still refused from a number, because
  # there is no number that describes one. `Vector3` goes through the shaped
  # path in section 12.
  ctx.release()

# ---------------------------------------------------------------------------
# 9. Hooks, as JSON
# ---------------------------------------------------------------------------
#
# Three, and they differ in what they cost and what they can see.
#
#   `hook`        a name comparison and nothing else. The handler is told only
#                 that the method fired.
#   `hookArgs`    the full Harmony prefix: what the method was called with, and
#                 the option to stop it.
#   `hookReturn`  the postfix: runs *after* the original and is the only one
#                 that can see, or change, what it returned.
#
# Arguments are opt-in because decoding them builds a JSON array inside a method
# the game may call thousands of times a frame. `hookArgs` on a per-bot,
# per-frame method is the wrong tool; `hook` is the right one, and section 11 is
# the right one after that.
#
# Four refusals, each of which could have been a guess:
#
#  * **Arguments past the fourth are not reported.** They arrive on the stack
#    rather than in registers and the host omits them rather than guessing. On
#    an instance method `this` takes the first register, so three declared
#    arguments are what fits.
#  * **A suppression whose replacement does not match the declared return type
#    is refused**, and the original runs. Skipping a method with garbage in the
#    return register is the worst outcome available.
#  * **`stopWith` from a handler that did not ask for arguments is refused**,
#    because a mod that believes it is suppressing when it is not would be
#    debugging the game instead of its own registration.
#  * **Two method shapes cannot carry a postfix at all** and are refused at
#    registration with a sentence saying which: a return type wider than eight
#    bytes, and a compiled call needing more than four register slots.
#
# **Two mods cannot hook one method.** The detour engine takes the method's
# first fourteen bytes, so there is one detour and one handler row per method
# across the whole process: `aowl_hook_attach` answers -9, "that method is
# already patched -- something else detoured it first", to whichever mod arms
# second. There is no merge and no chain, which is why every stage in this
# repository that runs two hooking mods gives each its own copy — and why the
# build command at the top of this file uses a stage of its own.
#
# This said the opposite until 2026-08-19: "every handler runs and the first one
# that asks to stop wins". A mod written to that would arm second, get a status
# it discarded, and never fire — the failure this whole file is arranged to make
# impossible, which is why the arm sites below all record `lastError()`.

var gReadyFires = 0
var gAimFires = 0
var gAimReplaced = 0

proc onReady(target: string) =
  ## The cheap hook. It is told the target and nothing else, and that is the
  ## whole point: no payload is built, so this is the shape for a method that
  ## fires often and only needs to be counted.
  inc gReadyFires

proc onAim(target, payload: string): HookResult =
  ## A postfix that *adjusts* the game's own answer.
  ##
  ## This is the shape for anything that scales, clamps or filters what the
  ## original produced. The prefix alternative is `stopWith`, which means
  ## reimplementing the method — and a reimplementation of a method you cannot
  ## read is a guess.
  ##
  ## `withArgs = false` at the arm site drops `this` and the arguments and keeps
  ## `result`, which is roughly five times cheaper: 440 ns a call against 2.4 us.
  inc gAimFires
  let r = hookResult(payload)
  if not r.ok:
    # `ok` is false when the payload carries no `result` — which is what a
    # *prefix* payload looks like. A handler registered the wrong way round
    # finds out here rather than scaling a zero.
    return keepResult()
  inc gAimReplaced
  replaceResult($(r.asFloat() * 0.5))

# ---------------------------------------------------------------------------
# 10. `this`, as an address — the bridge between the two halves
# ---------------------------------------------------------------------------
#
# A hook tells you *which* object something happened to. Reaching that object
# back through its handle means `call`, which is a name lookup, a JSON build, a
# boxed invoke and a JSON parse — about a microsecond, which on a method the
# game runs per entity per frame is a frame tax rather than a feature.
#
# `thisPointer(args)` is the one line that turns a hook from a notification into
# a place to do work: it hands back the **address**, which is what
# `aowlspt/fast`'s bindings take. Both numbers are measured below rather than
# quoted, in this process, on the same object, in the same firing.
#
# The lifetime rule is sharper here than anywhere else, because an address
# cannot defend itself. `this` and every reference argument stop being valid the
# moment the handler returns — the host reclaims them there, and that is a
# contract rather than a convenience: every reference argument costs a GC
# handle, so a per-frame per-bot hook whose author forgot to release one pins
# objects at several per second. Asking the host for an address *after* the
# handler returned is refused with `ErrDisposed`. Nothing can refuse an address
# the mod wrote down and used next frame, because by then it is just a number
# and the collector has moved the object underneath it.
#
# `pinHandle` is the honest way to keep one, and its cost is exactly what it
# sounds like: the object may not be moved for the rest of the session unless
# the mod releases the pin, and a pinned object in the middle of a generation is
# a hole every later collection compacts around. Pin the local player; do not
# pin what a hook hands you.

const PointerSamples = 200

var fTilt: FieldBinding
var fCondition: FieldBinding
var gPtrNs = -1'i64          ## address + bound field read, ns
var gBoxedNs = -1'i64        ## handle + boxed field read, ns
var gPtrSeen = 0'u64
var gTiltFires = 0
var gTiltSuppressed = 0
var gTiltPath = "not attempted"

var gCondFires = 0
var gCondArg = -1

proc onApplyCondition(target, payload: string): HookResult =
  ## A JSON prefix, kept as one deliberately: this is where `this` arrives as a
  ## handle, and the handle is what section 10 is about. An **enum** argument
  ## arrives as a plain number here, exactly as it does on the boxed call.
  inc gCondFires
  gCondArg = asInt(field(payload, "args[0]"), -1)
  measureThis(payload)
  carryOn()

proc measureThis(payload: string) =
  ## Runs once, inside a hook handler, on the object the hook fired for.
  if gPtrNs >= 0'i64:
    return
  let h = thisHandle(payload)
  let p = thisPointer(payload)
  gPtrSeen = p
  if h == 0'u64 or p == 0'u64 or not fTilt.ok:
    return

  let obj = cast[Il2CppPtr](p)
  let t0 = perfCounter()
  var i = 0
  var sink = 0.0
  while i < PointerSamples:
    sink = sink + readFloat(fTilt, obj)
    inc i
  gPtrNs = nanosBetween(t0, perfCounter()) div int64(PointerSamples)

  # The same read, through the handle the hook was actually given. A `GameObj`
  # is a handle, a type name and a flag, so one can be built from the handle in
  # hand — which is what `asObject` does for a call result.
  let boxed = GameObj(handle: h, typeName: TyCtx, ok: true)
  let t1 = perfCounter()
  i = 0
  while i < PointerSamples:
    sink = sink + boxed.field("Tilt").asFloat()
    inc i
  gBoxedNs = nanosBetween(t1, perfCounter()) div int64(PointerSamples)
  # `sink` is read so neither loop can be optimised away; without a use, the
  # measurement measures nothing.
  if sink == 12345.678:
    note "unreachable"

# --- the fallback discipline, written the way you would ship it -------------
#
# Two handlers for one hook: the typed one, and the JSON one for a host that has
# no typed path. Line for line they are the same decision. What differs is the
# machinery around it — and the machinery is a hundredfold.
#
# The arm site below is the shape every arm site in this file uses. Note that
# `typedPatchesReady()` and the install are one condition: a host that reports
# the capability and still refuses the install falls through to the JSON arm
# rather than ending up with no hook at all. And note that the recorded state
# names which path armed *and what the other one would have cost*, because
# "armed" on its own would hide the difference.

proc onSetTiltJson(target, payload: string): HookResult =
  ## The JSON prefix. Everything it needs is in the payload, at the price of the
  ## payload existing: a host-side string, a GC handle for `this`, a copy into
  ## this mod's heap, and a parse.
  inc gTiltFires
  measureThis(payload)
  let amount = asFloat(field(payload, "args[0]"), 0.0)
  if amount > gTiltCeiling:
    # `stopVoid()` for a method that returns nothing; `stopWith(json)` when it
    # returns something, and the value must match the declared return type or
    # the suppression is refused and the original runs.
    inc gTiltSuppressed
    return stopVoid()
  carryOn()

proc onSetTiltTyped(f: PatchFrame): TypedResult =
  ## The typed prefix. `this` is RCX and the float is XMM1; nothing is built,
  ## nothing is registered, nothing is parsed.
  inc gTiltFires
  var ok = false
  let amount = f.argFloat(0, ok)
  if not ok:
    # Reads are by index **and by declared kind**: `argFloat` on a slot the
    # runtime says is an integer is refused rather than reinterpreted, because
    # a `System.Single` sits in the low 32 bits of its XMM register and reading
    # it as a double gives a number unrelated to the argument. Letting the
    # original run is the only honest answer to a read that failed.
    return frameContinue()
  if amount <= gTiltCeiling:
    return frameContinue()
  if not f.setResultVoid():
    # The declared return is not void after all, so this handler cannot honestly
    # suppress: the caller would get whatever is in the return register.
    return frameContinue()
  inc gTiltSuppressed
  frameReplace()

proc armTilt() =
  ## Bind once, prefer the fast form, fall back cleanly, say which one you got.
  ## The two costs are named as "the typed row" and "the JSON row" rather than
  ## as numbers, because this file quotes no number it has not measured in this
  ## process — and at arm time nothing has been measured yet. Section 13 prints
  ## both rows, on this host, from twin methods with identical signatures.
  let target = TyCtx & "::SetTilt"
  if typedPatchesReady() and hookTyped(target, onSetTiltTyped) == Ok:
    gTiltPath = "armed on the typed path (the `prefix, typed frame` row in " &
                "section 13 is what a firing costs here)"
  elif hookArgs(target, onSetTiltJson) == Ok:
    gTiltPath = "armed on the JSON path — this host reports " &
                $hostApiSize() & " bytes of HostApi and the typed frame wants " &
                "revision 4 — at the `prefix, JSON payload` row in section 13 " &
                "rather than the typed one"
  else:
    gTiltPath = "refused: " & lastError()

# ---------------------------------------------------------------------------
# 11. Hooks, typed — and the measurement that justifies them
# ---------------------------------------------------------------------------
#
# `hookTyped` and `hookReturnTyped` are the same hooks with none of the payload.
# The handler is given a `PatchFrame`: a borrowed view of the registers the
# thunk already saved, plus the declared kind of every slot, worked out once
# when the patch was registered. It allocates nothing on either side and asks
# the runtime nothing per firing.
#
# **Do not reach for it by default.** JSON is self-describing, survives an
# argument the host cannot classify, reads a `System.String` for you, and 2 us
# at 10 Hz is 0.002 percent of a frame. This is for the hook that fires forty
# times a frame, where the difference is 5.3 ms a frame against 60 us.
#
# Three things to hold on to:
#
#  * `typedPatchesReady()` first, **and check what `hookTyped` returns**. The
#    test is a size test, so it says "there is a function here that will answer"
#    rather than "this works": on the backend and on `aowlspt-sim` the entry is
#    filled with a refusal, so the test passes and `hookTyped` answers
#    `ErrUnsupported`.
#  * Arguments past the fourth register position report as stack slots and
#    cannot be read — named rather than omitted, so argument *n* is always
#    declared parameter *n*.
#  * **The frame dies with your handler, and that is enforced.** Frames come
#    from a fixed pool rather than the stack, so a stored one reads as cleared
#    and `frameWhyText()` returns a sentence naming that exact mistake instead
#    of handing you undefined behaviour. This mod makes that mistake on purpose,
#    below, and prints the sentence.
#
# The four hooks armed here exist to be *measured*, not because a mod would want
# all four. They sit on four methods the stand-in provides as deliberate twins —
# `Ping`, `Sway`, `Sensitivity`, `Boost` are all `static float f(float)` with a
# real compiled body — so the typed and JSON numbers differ by the payload and
# by nothing else. The detour engine allows one hook per method, which is why
# each form needs its own twin rather than sharing a target.

var keptFrame = PatchFrame(p: cast[pointer](0))
var gKeptWhy = ""
var gKeptLiveInside = false

var gPingFires = 0        ## typed prefix
var gSwayFires = 0        ## JSON prefix
var gSensFires = 0        ## typed postfix, replacing
var gBoostFires = 0       ## JSON postfix, replacing

proc onPingTyped(f: PatchFrame): TypedResult =
  inc gPingFires
  # Kept deliberately past the end of the handler, once, so section 11 can print
  # what the frame says when it is read afterwards.
  if gPingFires == 1:
    keptFrame = f
    gKeptLiveInside = f.frameLive()
  frameContinue()

proc onSwayJson(target, payload: string): HookResult =
  inc gSwayFires
  carryOn()

proc onSensTyped(f: PatchFrame): TypedResult =
  ## A typed postfix that replaces the result. `resultFloat` reads XMM0 because
  ## the declared return says `System.Single`; asking for it as an integer is
  ## refused rather than answered out of RAX.
  inc gSensFires
  var ok = false
  let got = f.resultFloat(ok)
  if not ok:
    return frameContinue()
  if not f.setResultFloat(got * 2.0):
    return frameContinue()
  frameReplace()

proc onBoostJson(target, payload: string): HookResult =
  inc gBoostFires
  let r = hookResult(payload)
  if not r.ok:
    return keepResult()
  replaceResult($(r.asFloat() * 2.0))

# ---------------------------------------------------------------------------
# 12. The fast path
# ---------------------------------------------------------------------------
#
# `aowlspt/game` is the pleasant API and it is also the general one, which is
# why it costs about a microsecond a call. Once per frame per entity, that is
# the wrong budget. `aowlspt/fast` is the other shape: bind a method or a field
# once, then call through the binding. A bound call is 6–10 ns and a bound field
# read 1.9 ns, against 950–1100 ns for the boxed path — re-derived with
# `installer\build\perfbench.exe --runtime tests\mockil2cpp\GameAssembly.dll`,
# msys2 ucrt64 gcc 15.2.0. Section 13 measures its own versions of those in this
# process, which are the ones to trust on your machine.
#
# Three rules, none negotiable:
#
#  1. **Bind from inside a proc, never as a global initialiser** — the zeroed
#     global again. A zeroed `Binding` has `ok = false`, so it fails safe; it
#     also never becomes true.
#  2. **A bound call takes a raw pointer, not a `Handle`.** Resolve it fresh
#     each frame and do not store it. The collector moves objects.
#  3. **A binding that cannot express a signature refuses**, with a `why` that
#     names it. Log the `why` once. A refused binding is a mod that quietly does
#     nothing otherwise.
#
# And one rule about *what* to bind against:
#
#  4. **A bound call is non-virtual by construction.** It jumps to a compiled
#     body, so a binding taken by name against `EFT.Player` calls `EFT.Player`'s
#     implementation even when the object in hand is a bot subclass that
#     overrides it — silently, returning a plausible number. `bindOnObject`
#     binds against the class the object actually is, walking its base chain,
#     and is also the only way to reach a generic instantiation such as
#     `List<Player>`, which has no name `findClass` accepts. Use `bindMethod`
#     for a static or a method nothing overrides; use `bindOnObject` the moment
#     a subclass is possible.

var bCtxInstance: Binding     ## static  MovementContext get_Instance()
var bAimOnObject: Binding     ## instance float Aim(float), bound on the object
var bApplyCondition: Binding  ## instance void ApplyCondition(enum)
var bSetTilt: Binding         ## instance void SetTilt(float)
var bReady: Binding           ## instance bool Ready()
var bWorld: Binding           ## static  GameWorld get_Instance()
var bMainPlayer: Binding      ## instance Player get_MainPlayer()
var bPosition: Binding        ## the shaped Vector3 return
var bPing, bSway, bSens, bBoost: Binding
var gBound = false

proc reportBinding(label: string; b: Binding) =
  if b.ok:
    note padRight(label, 26) & b.why & " (bind " & $b.bindNs & " ns)"
  else:
    bad(12, "REFUSED " & label & " — " & b.why)

proc contextPointer(): Il2CppPtr =
  ## Resolved fresh, every time, which is rule 2. One bound static call.
  var a = noArgs()
  result = callPtr(bCtxInstance, nullPtr(), a)

# --- static fields, and why they are a different type -----------------------
#
# `bindStaticField` binds a **static** field, and its readers and writers
# **take no object**:
#
#     readFloat(fHealth, player)      # instance: a FieldBinding and an object
#     readInt(fSpawnCount)            # static:   a StaticFieldBinding, no object
#
# That is not a convenience. It is the only defence that holds, and here is the
# failure it holds against.
#
# A static field's offset is into the class's static data block; an instance
# field's is into the object. **The two ranges overlap completely**, because
# neither number knows about the other. In the stand-in runtime this file is
# measured against, `EFT.Player::SpawnCount` (static, `Int32`) and
# `EFT.Player::Health` (instance, `Single`) are both at offset 16 — which is not
# a contrivance, it is what independent numbering does.
#
# So getting the two confused is not a crash and not a refusal. An instance read
# of the static field reads whatever the object holds at that offset; a static
# read of the instance field reads whatever the static block holds. Both come
# back as numbers, both arrive with `ok` true, and a mod acts on them. This file
# prints the actual number the confusion produces, below, rather than describing
# it — because a plausible number is the entire hazard and it should be looked
# at.
#
# A `bool` flag on one type could not have prevented that: the wrong flag reads
# the same, and every call site would have had to check it. Two types means the
# **compiler** refuses, at every call site, for free.
#
# Staticness is asked of the runtime — `il2cpp_field_get_flags` — and not
# inferred from the offset, for exactly the reason above: an offset cannot tell
# the two apart. A runtime that does not export the flag is refused rather than
# guessed at, and so is one that does not export
# `il2cpp_class_get_static_field_data`, since adding an offset to a null block
# is how a mod reads address 16.
#
# `bindStaticField` runs the class's static constructor
# (`il2cpp_runtime_class_init`) before it reads the block, because a field that
# is zero because nothing has initialised it yet is otherwise
# indistinguishable from one that is zero.
#
# **`writePtrRaw` is the only pointer store a static field gets**, and the name
# says so. `il2cpp_gc_wbarrier_set_field` wants the *owning object* whose card
# the collector should mark; a static field has no owner — the block is a GC
# root in its own right, scanned on every collection. Passing the static block
# where an object header is expected is not a conservative choice, it is a wrong
# pointer handed to the collector. So there is no barriered form to reach for
# and the name does not let a caller believe otherwise. On an *instance* field
# the default is the other way round: `writePtr` goes through the barrier, and
# `writePtrRaw` is the opt-out.

var fSpawnCount: StaticFieldBinding   ## EFT.Player::SpawnCount, static Int32
var fSpawnRate: StaticFieldBinding    ## EFT.Player::SpawnRate,  static Single
var fHealth: FieldBinding             ## EFT.Player::Health, instance Single
var fPlayerRef: FieldBinding          ## EFT.MovementContext::_player, a reference

proc bindStatics() =
  ## Binds the colliding pair, and shows each binding refusing the other's
  ## field. The refusals are printed even though they are the boring outcome:
  ## a refusal nobody looks at is a refusal nobody notices going missing.
  fHealth = bindField(rt, TyPlayer, "Health")
  fSpawnCount = bindStaticField(rt, TyPlayer, "SpawnCount")
  fSpawnRate = bindStaticField(rt, TyPlayer, "SpawnRate")

  if fSpawnCount.ok:
    note padRight("SpawnCount (static)", 26) & fSpawnCount.why &
         " (bind " & $fSpawnCount.bindNs & " ns)"
  else:
    bad(12, "REFUSED SpawnCount — " & fSpawnCount.why)
  if fSpawnRate.ok:
    note padRight("SpawnRate (static float)", 26) & fSpawnRate.why
  if fHealth.ok:
    note padRight("Health (instance)", 26) & fHealth.why

  if fHealth.ok and fSpawnCount.ok:
    if fHealth.offset == fSpawnCount.offset:
      note "the two offsets are the same number, " & $fHealth.offset &
           " -- one into an object, one into the class's static block. " &
           "Nothing about either number says which"
    else:
      note "on this runtime the two offsets happen to differ (" &
           $fHealth.offset & " and " & $fSpawnCount.offset & "), which is " &
           "luck rather than a guarantee: nothing makes them differ"

  # Each binding refusing the other's field, which is the runtime's answer
  # rather than an offset heuristic.
  let asInstance = bindField(rt, TyPlayer, "SpawnCount")
  let asStatic = bindStaticField(rt, TyPlayer, "Health")
  if asInstance.ok:
    bad(12, "bindField accepted the static field SpawnCount; the runtime is " &
            "not reporting field flags and reads off an object would be bytes")
  else:
    note "bindField(SpawnCount) refused: " & asInstance.why
  if asStatic.ok:
    bad(12, "bindStaticField accepted the instance field Health, which would " &
            "read the static block at an instance field's offset")
  else:
    note "bindStaticField(Health) refused: " & asStatic.why

proc bindEverything(): bool =
  ## Called from `onUpdate`, on the first tick the types resolve — never from
  ## `onLoad`. `findClass` walks every loaded assembly, and at load time the
  ## game's own assemblies are not among them, so a binding made then would
  ## correctly refuse and never be retried.
  if gBound:
    return true
  if not openRuntime():
    return false

  say(12, "binding, once, against the runtime this mod is already inside")
  # Measured, not assumed, and the measurement is why an enum binds at all.
  # `il2cpp_class_get_instance_size` on the game reports a value type's *boxed*
  # size, header plus payload; a stand-in can just as reasonably report the
  # payload, and both answers are self-consistent, so no single number in
  # isolation tells them apart. One number whose payload is known does:
  # `System.Int32` holds four bytes by definition, so whatever this runtime
  # reports for it, minus four, is the header. **0 is a legitimate answer** and
  # means this runtime reports payloads. Getting it wrong subtracts a header
  # that is not there, which turns every small value type into a negative width
  # and refuses it -- an enum reported as unclassifiable, and a log line saying
  # the shape was checked.
  note "object header measured at " & $boxHeaderBytes(rt) &
       " bytes, from System.Int32 (payload 4 by definition) cross-checked " &
       "against System.Double -- assuming 16 is how an enum used to be refused"

  bCtxInstance = bindMethod(rt, TyCtx, "get_Instance", 0)
  reportBinding("get_Instance (static)", bCtxInstance)
  if not bCtxInstance.ok:
    return false

  let ctx = contextPointer()
  if ctx == nil:
    note "no live MovementContext, so the object-bound half cannot be shown"
    return false

  # Rule 4, applied. `Aim` is an instance method and a subclass could override
  # it, so it is bound against the object rather than against the name.
  bAimOnObject = bindOnObject(rt, ctx, "Aim", [fkF32], fkF32)
  reportBinding("Aim (on the object)", bAimOnObject)

  # An **enum parameter binds on the fast path**. It used to be refused: an enum
  # passes as its underlying integer, nothing in the C API names which one, and
  # guessing Int32 is wrong for the `long` enums that exist. The width is not a
  # guess — it is instance size minus the *measured* object header — so an enum,
  # and any other value type small enough to travel in a register, is classified
  # by the size the runtime reports for it.
  bApplyCondition = bindMethod(rt, TyCtx, "ApplyCondition", 1)
  reportBinding("ApplyCondition (enum)", bApplyCondition)

  bSetTilt = bindMethod(rt, TyCtx, "SetTilt", 1)
  reportBinding("SetTilt", bSetTilt)
  bReady = bindMethod(rt, TyCtx, "Ready", 0)
  reportBinding("Ready", bReady)

  fTilt = bindField(rt, TyCtx, "Tilt")
  if fTilt.ok:
    note padRight("Tilt (field)", 26) & fTilt.why & " (bind " & $fTilt.bindNs & " ns)"
  else:
    bad(12, "REFUSED Tilt — " & fTilt.why)
  fCondition = bindField(rt, TyCtx, "Condition")
  if fCondition.ok:
    note padRight("Condition (enum field)", 26) & fCondition.why

  # A reference field, for section 12's write-barrier half.
  fPlayerRef = bindField(rt, TyCtx, "_player")
  if fPlayerRef.ok:
    note padRight("_player (reference)", 26) & fPlayerRef.why &
         "; writePtr goes through the collector: " & $fPlayerRef.barrierReady()

  bindStatics()

  # The four twins the measurements in section 13 are taken on. Bound with
  # `bindMethodAs` rather than by inference, deliberately: section 13 claims
  # what a *call* costs, so the call it times has to be the correctly shaped
  # one. `bBoost` below is bound both ways, so the difference is visible.
  bPing = bindMethodAs(rt, TyPlayer, "Ping", [fkF32], fkF32)
  bSway = bindMethodAs(rt, TyPlayer, "Sway", [fkF32], fkF32)
  bSens = bindMethodAs(rt, TyPlayer, "Sensitivity", [fkF32], fkF32)
  bBoost = bindMethod(rt, TyPlayer, "Boost", 1)

  bWorld = bindMethod(rt, "EFT.GameWorld", "get_Instance", 0)
  bMainPlayer = bindMethod(rt, "EFT.GameWorld", "get_MainPlayer", 0)

  # --- stating the call shape outright --------------------------------------
  #
  # `bindMethod` infers register classes from the declared signature and refuses
  # what it cannot classify. Watch it refuse, first, and read the `why`:
  let inferred = bindMethod(rt, TyPlayer, "get_Position", 0)
  if inferred.ok:
    note "get_Position bound by inference, which this runtime allows"
  else:
    note "bindMethod refuses get_Position, correctly: " & inferred.why

  # A `Vector3` is twelve bytes. Win64 passes anything larger than eight bytes
  # and not a power of two **by hidden pointer**, and returns it the same way,
  # so
  #
  #     Vector3 Player::get_Position()      is really
  #     void*   get_Position(void* sret, void* this, MethodInfo*)
  #
  # Every slot there is a plain pointer, which the trampolines already pass.
  # `bindRaw` is how you say "this method has two native slots" when its
  # signature says it takes no arguments.
  #
  # **This is the sharpest tool in the module and it is the last resort.** You
  # are asserting a calling convention: a wrong slot count reads an
  # uninitialised register as an argument, which is a plausible number rather
  # than a crash — the failure mode with the longest time-to-diagnosis
  # available. Every use of it should carry a comment saying why the shape is
  # what it claims, and this one does: 0 declared arguments, 2 native slots
  # (the hidden return pointer, then `this`), no slot is a float so the mask is
  # 0, and the return is the same pointer.
  let playerCls = findClass(rt, TyPlayer)
  if playerCls != nil:
    bPosition = bindRaw(rt, playerCls, TyPlayer, "get_Position", 0, 2, 0'u32, fkPtr)
    reportBinding("get_Position (shaped)", bPosition)

  gBound = true
  result = true

proc playerPointer(): Il2CppPtr =
  ## The live player, resolved fresh through two bound calls. Rule 2 again:
  ## nothing here is stored between frames.
  result = nullPtr()
  if not (bWorld.ok and bMainPlayer.ok):
    return
  var a = noArgs()
  let w = callPtr(bWorld, nullPtr(), a)
  if w == nil:
    return
  a.reset()
  result = callPtr(bMainPlayer, w, a)

proc useStaticFields() =
  ## The static pair, read and written with no object anywhere in sight — and
  ## the number the confusion this prevents would have produced.
  if fSpawnCount.ok:
    note "readInt(SpawnCount) -> " & $readInt(fSpawnCount) &
         "   (no object argument: that is the type doing the work)"
  if fSpawnRate.ok:
    note "readFloat(SpawnRate) -> " & $readFloat(fSpawnRate) &
         "   (read at its declared width, not at an assumed four bytes)"

  # The failure, shown rather than described. `Health` is a `Single` at the same
  # offset the static `SpawnCount` lives at, so reading that object at that
  # offset *as an integer* is exactly what an instance binding of the static
  # field would have done. This is a safe read of a field this mod legitimately
  # bound; the point is the number that comes back.
  let player = playerPointer()
  if fHealth.ok and player != nil:
    let asFloat = readFloat(fHealth, player)
    let asBits = readInt(fHealth, player)
    note "the same object at offset " & $fHealth.offset & " reads " & $asFloat &
         " as a float and " & $asBits & " as an integer. Neither call fails, " &
         "neither answer is flagged, and " & $asBits & " is what a mod that " &
         "bound a static field as an instance field would have acted on"

  # A write, and then the read that proves it landed somewhere the runtime
  # agrees about. The boxed path is the second opinion: it goes through
  # `il2cpp_field_static_get_value` rather than through this offset, so the two
  # agreeing is what makes the address right rather than lucky.
  if fSpawnCount.ok:
    writeInt(fSpawnCount, 4242)
    let back = readInt(fSpawnCount)
    let boxed = Player.field("SpawnCount")
    note "writeInt(SpawnCount, 4242) then readInt -> " & $back &
         "; the boxed path reads " &
         (if boxed.ok: boxed.raw else: "refused (" & boxed.error & ")") &
         (if boxed.ok and boxed.asInt() == back:
            " -- two mechanisms, one answer"
          else:
            " -- and they disagree, which means one of them is not looking " &
            "at the field")

  # `writePtrRaw` on an *instance* reference field is the opt-out from the
  # barrier, for the one case that is genuinely safe: writing back a pointer the
  # object already reachably holds. Clearing and restoring is that case, and it
  # is also the only way to show a store landed at all — writing back what was
  # already there reads correctly whether or not the write happened.
  let ctx = contextPointer()
  if fPlayerRef.ok and ctx != nil:
    let had = readPtr(fPlayerRef, ctx)
    writePtr(fPlayerRef, ctx, nullPtr())      # barriered, the default
    let cleared = readPtr(fPlayerRef, ctx)
    writePtrRaw(fPlayerRef, ctx, had)         # unbarriered, and safe here
    let restored = readPtr(fPlayerRef, ctx)
    note "_player: writePtr(nil) left it " &
         (if cleared == nullPtr(): "null" else: "unchanged, so the store did " &
          "not land") & ", writePtrRaw put it back " &
         (if restored == had: "correctly" else: "wrongly") &
         ". writePtr went through the collector: " & $fPlayerRef.barrierReady() &
         " -- and the raw form was safe only because that pointer was already " &
         "reachable from this object a line earlier"

proc useFastPath() =
  ## One pass of everything bound above, with the numbers it produced.
  let ctx = contextPointer()
  if ctx == nil:
    return

  if fTilt.ok:
    # A bound field read is a load from `object + offset`. Nothing else.
    writeFloat(fTilt, ctx, 2.5)
    note "readFloat(Tilt) after writeFloat(2.5) -> " & $readFloat(fTilt, ctx)

  if fCondition.ok:
    # An enum field reads as a plain number too, at the width the runtime
    # reports rather than at an assumed four bytes.
    note "readInt(Condition) -> " & $readInt(fCondition, ctx) & " (a number, " &
         "not a handle)"

  useStaticFields()

  if bApplyCondition.ok:
    var a = noArgs()
    addInt(a, 1)
    callVoid(bApplyCondition, ctx, a)
    note "ApplyCondition(1) through the bound enum parameter; Condition now " &
         (if fCondition.ok: $readInt(fCondition, ctx) else: "unreadable")

  if bSetTilt.ok:
    # Two calls, one either side of `tiltCeiling`, so the hook on SetTilt has
    # something to let through and something to suppress.
    var a = noArgs()
    addFloat(a, 1.0)
    callVoid(bSetTilt, ctx, a)
    let passed = (if fTilt.ok: readFloat(fTilt, ctx) else: 0.0)
    a.reset()
    addFloat(a, gTiltCeiling + 1.0)
    callVoid(bSetTilt, ctx, a)
    let stopped = (if fTilt.ok: readFloat(fTilt, ctx) else: 0.0)
    note "SetTilt(1.0) left Tilt at " & $passed & "; SetTilt(" &
         $(gTiltCeiling + 1.0) & ") was above the ceiling and Tilt is still " &
         $stopped & (if passed == stopped: " -- suppressed" else: " -- it ran")

  if bAimOnObject.ok:
    var a = noArgs()
    addFloat(a, 1.0)
    note "Aim(1.0) on the object-bound call -> " & $callFloat(bAimOnObject, ctx, a)

  if bReady.ok:
    var a = noArgs()
    note "Ready() -> " & $callBool(bReady, ctx, a)

  # **Check a binding once against a value you can predict**, before trusting
  # it in a loop. A float that went into a general-purpose register instead of
  # an XMM one answers a *number* rather than crashing, and a plausible number
  # is the failure shape with the longest time-to-diagnosis available.
  #
  # Predicting the value means counting your own hooks. `Boost` multiplies by
  # three, so 4.0 is 12.0 out of the method -- but section 9 armed a postfix on
  # it that doubles the result, so 24.0 is what a caller sees, and that is what
  # this checks against. The first draft of this file expected 12.0 and forgot
  # the hook it had installed twenty lines earlier. It read as a failing
  # binding for as long as the binding really was broken, and would have gone
  # on reading that way after the fix -- which is how a wrong expectation
  # survives being right about something.
  const BoostExpected = 24.0
  if bBoost.ok:
    var a = noArgs()
    addFloat(a, 4.0)
    let got = callFloat(bBoost, nullPtr(), a)
    note "Boost(4.0) through the inferred binding -> " & $got &
         (if got == BoostExpected: "  (3x in the method, 2x in our own postfix)"
          else: "  MISMATCH: expected " & $BoostExpected & ". The binding says " &
                "it returns " & describe(bBoost.ret) & ", and the method is " &
                "declared System.Single -- if those disagree, the argument " &
                "went to a general-purpose register and the answer was read " &
                "out of RAX. State the kinds with bindMethodAs and move on; " &
                "this is what checking once buys")

    # And the escape hatch, so the check has somewhere to go. `bindMethodAs`
    # asserts the register classes instead of inferring them: the mod is saying
    # what the signature is, and it is on the mod to be right -- which is why
    # the inferring form exists and this is the exception.
    #
    # Both lines print, always, even when they agree. Two numbers side by side
    # are how you tell "inference works here" from "inference was never
    # exercised", and only one of those is worth trusting a raid to.
    let asserted = bindMethodAs(rt, TyPlayer, "Boost", [fkF32], fkF32)
    if asserted.ok:
      var b2 = noArgs()
      addFloat(b2, 4.0)
      let stated = callFloat(asserted, nullPtr(), b2)
      note "Boost(4.0) through bindMethodAs([fkF32], fkF32) -> " & $stated &
           (if stated == got: "  (the same, so inference got this one right)"
            else: "  -- and the inferred binding said " & $got &
                  ", which is the bug")

  # The shaped call. `ShapedArgs` is filled positionally and nothing about it is
  # inferred: slot 0 is whatever the mod says slot 0 is.
  if bPosition.ok and bWorld.ok and bMainPlayer.ok:
    var a = noArgs()
    let w = callPtr(bWorld, nullPtr(), a)
    if w != nil:
      a.reset()
      let player = callPtr(bMainPlayer, w, a)
      if player != nil:
        var out3: array[3, float32] = [0.0'f32, 0.0'f32, 0.0'f32]
        var s = shaped()
        addSlotPtr(s, cast[Il2CppPtr](addr out3[0]))   # the hidden return slot
        addSlotPtr(s, player)                          # this
        discard callShapedPtr(bPosition, s)
        note "get_Position through the shaped call -> (" & $out3[0] & ", " &
             $out3[1] & ", " & $out3[2] & ")"

# ---------------------------------------------------------------------------
# 13. The measurements
# ---------------------------------------------------------------------------
#
# Everything above claims a number. Here it is measured, in this process, on
# this machine, through the bindings from section 12 — and printed with what it
# was measured on, because a performance claim that is not re-checked is a
# performance claim that has quietly stopped being true.
#
# The baseline is taken on `Boost` **before** its postfix is armed, so
# "unpatched" is the same method later measured patched, rather than a different
# one assumed to be equivalent.
#
# `perfCounter`, `perfFreq` and `nanosBetween` come from `aowlspt/fast`: the
# same clock the bindings report their own bind cost on, and the right
# resolution for a hot loop where `nowMs()` is off by three orders of magnitude.

var gBareNs = -1'i64
var gTypedPreNs = -1'i64
var gJsonPreNs = -1'i64
var gTypedPostNs = -1'i64
var gJsonPostNs = -1'i64
var gAllocDelta = -1'i64
var gAllocProbe = false

proc timeCalls(b: Binding): int64 =
  ## `gSamples` calls through one binding, in nanoseconds per call, or -1 when
  ## the binding refused. Nothing is allocated inside the loop, on purpose: this
  ## is the one procedure whose cost is claimed, and a string anywhere in it
  ## would make the claim false.
  if not b.ok:
    return -1'i64
  var a = noArgs()
  addFloat(a, 4.0)
  var i = 0
  var sink = 0.0
  let t0 = perfCounter()
  while i < gSamples:
    a.reset()
    addFloat(a, 4.0)
    sink = sink + callFloat(b, nullPtr(), a)
    inc i
  let ns = nanosBetween(t0, perfCounter()) div int64(gSamples)
  if sink == 1.0e30:
    note "unreachable"
  result = ns

var gStaticReadNs = -1'i64
var gInstanceReadNs = -1'i64

proc timeStaticReads(f: StaticFieldBinding): int64 =
  ## `gSamples` reads of a static field, in nanoseconds each.
  ##
  ## Measured beside the instance read below rather than asserted to be the
  ## same, because "a static read is the same one load from a constant base"
  ## is a claim about generated code and this file's rule is that it does not
  ## make claims it has not watched.
  if not f.ok:
    return -1'i64
  var i = 0
  var sink = 0'i64
  let t0 = perfCounter()
  while i < gSamples:
    sink = sink + readInt(f)
    inc i
  let ns = nanosBetween(t0, perfCounter()) div int64(gSamples)
  if sink == -1'i64:
    note "unreachable"
  result = ns

proc timeInstanceReads(f: FieldBinding; obj: Il2CppPtr): int64 =
  if not f.ok or obj == nil:
    return -1'i64
  var i = 0
  var sink = 0.0
  let t0 = perfCounter()
  while i < gSamples:
    sink = sink + readFloat(f, obj)
    inc i
  let ns = nanosBetween(t0, perfCounter()) div int64(gSamples)
  if sink == 1.0e30:
    note "unreachable"
  result = ns

var bBoostShaped: Binding

proc measureBaseline() =
  ## Taken on `Boost` **before** anything is patched on it, so "unpatched" is
  ## the same method later measured patched rather than a different one assumed
  ## to be equivalent.
  bBoostShaped = bindMethodAs(rt, TyPlayer, "Boost", [fkF32], fkF32)
  gBareNs = timeCalls(bBoostShaped)

proc measurePatched() =
  gTypedPreNs = timeCalls(bPing)
  gJsonPreNs = timeCalls(bSway)
  gTypedPostNs = timeCalls(bSens)
  gJsonPostNs = timeCalls(bBoostShaped)
  gStaticReadNs = timeStaticReads(fSpawnCount)
  gInstanceReadNs = timeInstanceReads(fHealth, playerPointer())

  # And the claim that the typed path allocates nothing at all. The counter is
  # cumulative — a free does not lower it — which is the whole reason it can
  # prove this: an unchanged number across a loop means the loop allocated
  # nothing, where a live-bytes figure would sit still for a string built and
  # freed once per firing.
  gAllocProbe = allocProbeOk()
  if gAllocProbe and bPing.ok:
    let before = allocationCount()
    var a = noArgs()
    var i = 0
    var sink = 0.0
    while i < 2000:
      a.reset()
      addFloat(a, 4.0)
      sink = sink + callFloat(bPing, nullPtr(), a)
      inc i
    gAllocDelta = allocationCount() - before
    if sink == 1.0e30:
      note "unreachable"

proc row(label: string; ns: int64; baseline: int64) =
  var s = "  " & padRight(label, 34)
  if ns < 0'i64:
    s.add padLeft("--", 8) & "   (not measured here)"
  else:
    s.add padLeft($ns, 8) & " ns"
    if baseline > 0'i64 and ns > 0'i64:
      s.add "   " & padLeft($(ns div baseline), 5) & "x the unpatched call"
  info ModName & "  " & s

proc reportMeasurements() =
  say(13, "measured in this process, " & $gSamples & " calls a row, on " &
          hostName() & ":")
  row("unpatched bound call", gBareNs, 0'i64)
  row("prefix, typed frame", gTypedPreNs, gBareNs)
  row("prefix, JSON payload", gJsonPreNs, gBareNs)
  row("postfix + replace, typed frame", gTypedPostNs, gBareNs)
  row("postfix + replace, JSON payload", gJsonPostNs, gBareNs)
  if gTypedPreNs > 0'i64 and gJsonPreNs > 0'i64:
    good(13, "the typed prefix is " & $(gJsonPreNs div gTypedPreNs) &
             " times cheaper than the JSON one on this host, on two methods " &
             "with identical signatures and identical bodies")
  if gAllocDelta >= 0'i64:
    good(13, "2000 typed firings allocated " & $gAllocDelta &
             " blocks in this mod (the counter is cumulative, so 0 means none " &
             "at all rather than none net)")
  elif not gAllocProbe:
    note "the allocation counter is not readable in this build, so the " &
         "allocation claim is not made rather than made without evidence"

  if gStaticReadNs >= 0'i64 or gInstanceReadNs >= 0'i64:
    say(13, "and the two field reads, " & $gSamples & " each:")
    row("static field read (no object)", gStaticReadNs, 0'i64)
    row("instance field read (+ object)", gInstanceReadNs, 0'i64)
    note "the same single load either way -- the static one from a base the " &
         "binding resolved once, the instance one from the object handed in. " &
         "The reason for two types was never the cost; it was that neither " &
         "read can fail loudly when it is pointed at the wrong base"

  say(13, "and the address bridge, measured on one object in one hook firing:")
  row("bound field read via thisPointer", gPtrNs, 0'i64)
  row("boxed field read via the handle", gBoxedNs, 0'i64)
  if gPtrNs > 0'i64 and gBoxedNs > 0'i64:
    good(13, "the address is " & $(gBoxedNs div gPtrNs) &
             " times cheaper than the handle it came from")

# ---------------------------------------------------------------------------
# Arming, and saying what could not be armed
# ---------------------------------------------------------------------------

var gArmed = false
var gHookState: seq[string] = @[]

proc armOne(label, target: string; st: Status) =
  if st == Ok:
    gHookState.add label & ": armed"
  else:
    gHookState.add label & ": refused (" & lastError() & ")"

proc armHooks() =
  # Baseline before anything is on `Boost`.
  measureBaseline()

  armOne("hook(Ready)", TyCtx & "::Ready", hook(TyCtx & "::Ready", onReady))
  armOne("hookReturn(Aim, withArgs=false)", TyCtx & "::Aim",
         hookReturn(TyCtx & "::Aim", onAim, withArgs = false))
  # Section 10's own hook, and the one place this file keeps the JSON prefix on
  # purpose: `this` arrives as a handle here, and turning that handle into an
  # address is the whole of section 10.
  armOne("hookArgs(ApplyCondition)", TyCtx & "::ApplyCondition",
         hookArgs(TyCtx & "::ApplyCondition", onApplyCondition))

  # Section 10's fallback discipline.
  armTilt()
  gHookState.add "SetTilt: " & gTiltPath

  # Section 11's four, armed explicitly one way each because they exist to be
  # compared. A shipping mod would use the `armTilt` shape instead.
  if gCanTyped:
    armOne("hookTyped(Ping)", TyPlayer & "::Ping",
           hookTyped(TyPlayer & "::Ping", onPingTyped))
    armOne("hookReturnTyped(Sensitivity)", TyPlayer & "::Sensitivity",
           hookReturnTyped(TyPlayer & "::Sensitivity", onSensTyped))
  else:
    gHookState.add "hookTyped(Ping): not attempted, this host has no typed path"
    gHookState.add "hookReturnTyped(Sensitivity): not attempted, same reason"
  armOne("hookArgs(Sway)", TyPlayer & "::Sway",
         hookArgs(TyPlayer & "::Sway", onSwayJson))
  armOne("hookReturn(Boost)", TyPlayer & "::Boost",
         hookReturn(TyPlayer & "::Boost", onBoostJson))

  say(9, "hooks:")
  for s in gHookState:
    note s

proc reportHooks() =
  good(9, "firings: Ready " & $gReadyFires & ", Aim " & $gAimFires &
          " (" & $gAimReplaced & " results replaced), SetTilt " & $gTiltFires &
          " (" & $gTiltSuppressed & " suppressed above tiltCeiling=" &
          $gTiltCeiling & ")")
  good(10, "ApplyCondition fired " & $gCondFires & " time(s); the enum " &
           "argument arrived as the plain number " & $gCondArg &
           ", and `this` came back as address " & $gPtrSeen &
           " -- valid only for the length of that handler")
  good(11, "firings: Ping(typed) " & $gPingFires & ", Sway(JSON) " &
           $gSwayFires & ", Sensitivity(typed postfix) " & $gSensFires &
           ", Boost(JSON postfix) " & $gBoostFires)

  # The frame kept past its handler, on purpose.
  if gPingFires > 0:
    say(11, "the frame this mod deliberately kept past its handler:")
    note "inside the handler frameLive() was " & $gKeptLiveInside &
         "; afterwards it is " & $keptFrame.frameLive()
    var ok = true
    discard keptFrame.argFloat(0, ok)
    gKeptWhy = frameWhyText()
    note "reading it now is refused, and the host says: " & gKeptWhy

proc reportWhatRan() =
  ## Every section, with whether it ran here and why not when it did not.
  ##
  ## A capability that is silently absent is indistinguishable from one that is
  ## broken, and a mod that goes quiet is the reason somebody spends an evening
  ## on a host that was answering correctly all along. So the verdict is per
  ## facility and it is printed on every host, including the one where
  ## everything worked.
  if gReported:
    return
  gReported = true

  if gRuntimeOk:
    good(13, "sections 8 to 13 ran against a live IL2CPP runtime")
    return

  bad(8, "no IL2CPP runtime in this process, so sections 9 to 13 could not " &
         "run. Named rather than skipped:")
  if gTypeSeen:
    note "8   the boxed path ran and every call was refused by name. Worth " &
         "noticing: `resolve` **succeeded** here. This host answers it with a " &
         "name and nothing behind it, so a type resolving is not proof there " &
         "is a game -- the proof is a call that returns a value."
  note "9   hook / hookArgs / hookReturn -- patch is unsupported: there is no " &
       "compiled game code in this process to detour"
  note "10  thisPointer -- livePointersReady() is " & $gCanPointers &
       ", and a handle here names a host object with no managed address to give"
  note "11  hookTyped / hookReturnTyped -- typedPatchesReady() is " &
       $gCanTyped & ", and the entry behind it is filled with the refusal it " &
       "already owed, so that one `size` integer can say \"the fourth and not " &
       "the fifth\". This is exactly why the arm sites check the *status* too."
  note "12  the fast path -- openIl2Cpp() found no GameAssembly.dll to bind"
  note "13  the measurements -- nothing to measure, so no numbers are printed " &
       "rather than zeros that would read as numbers"
  note "run it against the stand-in instead; the header of this file has the " &
       "four commands"

# ---------------------------------------------------------------------------
# The three entry points
# ---------------------------------------------------------------------------

proc onLoad(): Status =
  reportEnvironment()
  readConfig()
  useStore()
  armEvents()
  armSchedule()
  Ok

proc onUpdate(elapsedMs: int64): Status =
  inc gTicks

  # `whenReady` is true exactly once, on the first tick its type resolves. It
  # exists because "the game is up" is not an event the client host can observe
  # — assemblies arrive when they arrive — and polling for a type that only
  # exists once the world does is the honest way to wait for it.
  if world.ready():
    gTypeSeen = true
    good(8, "EFT.MovementContext resolves, so this host will answer by name")
    boxedPath()
    if bindEverything():
      gRuntimeOk = true
      armHooks()
      gArmedHooks = true
      useFastPath()

  # The hooks need a few ticks of the game calling the methods before the
  # firing counts mean anything, and the measurements need the hooks armed.
  if gArmedHooks and gTicks == 12:
    measurePatched()
    reportHooks()
    reportMeasurements()

  queueOneMore()

  # The `everyMain` chain is stopped well before the report reads it, so that
  # "one further firing got through" is a gap that was actually waited out
  # rather than a number taken in the same breath as the stop.
  if gTicks == 2:
    stopRepeats(gTicks)

  # One report, once. Twelve ticks on a real host; three is the whole run in
  # the simulator, so whichever comes first.
  if gTicks == 3 and not gRuntimeOk:
    reportSchedule()
    reportWhatRan()
  elif gTicks == 24:
    reportSchedule()
    reportWhatRan()
  Ok

proc onUnload(): Status =
  ## Everything a mod registered is a function pointer into its library — a
  ## route, a subscription, a timer, a detour — and the *host* drops all of them
  ## after this returns and before it frees the library. So this proc is not for
  ## unregistering; it is for putting the game back the way it was found, and
  ## for saying what happened.
  ##
  ## Do not queue work onto the main thread from here and return. The host's
  ## teardown removes the queued callback before it ever runs, and the log line
  ## saying "queued" would be the only trace that nothing happened.
  if gCanStore:
    discard save("lesson.runs", "{\"runs\":" & $gRuns & "}")
  info ModName & "  unloaded after " & $gTicks & " ticks, " & $gEventsHeard &
       " event(s) heard, " & $gTimerFires & " timer firing(s)"
  Ok

exportMod(
  guid = "aowl.lesson",
  name = "Lesson",
  author = "aowlspt",
  version = "1.0.0",
  sptRange = "*",
  sides = {sideServer, sideClient, sideSim},
  onLoad = onLoad,
  onUpdate = onUpdate,
  onUnload = onUnload,
  stateSave = stateSave,
  stateLoad = stateLoad,
  flags = {mfHotReloadable})
