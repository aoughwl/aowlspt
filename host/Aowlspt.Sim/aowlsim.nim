## aowlspt-sim -- run a native mod with no game and no server.
##
##     aowlspt-sim <mod-dir-or-library> [options]
##
## This is the piece that makes native modding bearable. Without it the edit
## loop is: build, start the backend (or the whole game), get into a raid, find
## out the mod is wrong, kill everything, repeat. With it the loop is one
## command that runs in under a second, in a process a debugger can attach to
## like any other.
##
## It loads a mod through `host/common/modhost.nim` -- the same loader the
## backend and the client host use, the same version probe, the same
## `describe`/`init`/`on_load`, the same unload order -- so "it loads in the
## simulator" means the thing it sounds like. What differs is only what is
## underneath the host API, and this file is that.
##
## ## What it can and cannot do, and why the difference is stated rather than
## ## papered over
##
## Real, because they need nothing but this process:
##
##   * the **store** (`store_get`/`store_set`/`store_list`) -- the same
##     `modstore.nim` the backend writes profiles with, rooted in a scratch
##     directory rather than an install. This is the reason the simulator was
##     rewritten: at ABI revision 1 it had no store, so every mod that persists
##     anything -- `mods/tarkov` above all -- could not be simulated at all.
##   * the **database** (`db_get`/`db_patch`), from a JSON file you supply with
##     `--db`, through the backend's own `jsondb` so that a merge means here
##     what it means there.
##   * **routes**, **events**, **timers**, **config**, **logging**, and live
##     **mod control** -- the manager can enumerate and unload mods here.
##
## Refused, because there is no runtime behind them and a plausible answer is
## worse than a refusal:
##
##   * `patch` -- there is no compiled game code in this process to detour, so
##     a hook answers `AOWLSPT_ERR_UNSUPPORTED` with a sentence saying so.
##   * `call` -- the same, unless you scripted the target with `--stubs`, which
##     is a human explicitly saying "answer this one with that". Anything not
##     in the file is refused rather than guessed at, so no value, field or
##     firing in this process is ever invented.
##   * `resolve` is the one exception and `hostResolve` argues it: it hands
##     back a *name*, because a mod resolves its types at load and gates
##     everything else behind that, and a handle whose only use refuses is
##     cheaper than making twenty rules untestable outside a game.
##   * `handle_pointer`, `handle_pin`, `patch_typed` -- filled in with the
##     refusal they already owe, and only then is `AowlHostApi.size` raised to
##     revision 4. See `aowl_hostapi_arm_sim` below.
##   * `notify_push` (revision 5) is not filled at all: it needs a websocket,
##     and there is none here. That is why the watermark stops at 4.
##   * `db_get`, `db_patch` and `route_register` **under `--side client`**.
##     They work on the server and sim sides and are refused on the client one,
##     in the client host's own words, because that is what the client host
##     does -- a mod developed against a simulator that served a database to
##     its client half would find out in a raid.
##
## Said out loud rather than left to be discovered:
##
##   * A file named on the command line that cannot be parsed stops the run.
##     `--db` and `--stubs` that are missing, empty or not a JSON object used
##     to be a warning, and every `db_get` and `call` afterwards then described
##     the *mod* ("no database entry at ...", "no stub for ...") for a fault
##     that was in the file.
##   * A `config.json` that does not parse is reported as a file that did not
##     parse, distinctly from a key that is not in it.
##   * `--watch` reloads by unload-and-load, and **nothing in the mod's memory
##     crosses it**: no host in this repository calls `state_save`/`state_load`
##     yet, this one included. A mod flagged `AOWLSPT_MOD_HOT_RELOADABLE` is
##     told so by name, because it is the one mod that would otherwise assume
##     its `stateLoad` had run.
##   * A mod excluded by an `aowlspt-selection.json` next to it still runs
##     here -- the simulator loads the mod you name -- and says that an
##     installed host would not have loaded it.

import std/[strutils, syncio, cmdline, envvars]
import aowlsptinstall/winfs
import modhost
import modcontrol
import modstore
import jsonpath
import jsondb

# The shim first: it defines the ABI types and the `aowl_sys_*` helpers the
# loader calls. `modhost` includes it too and the guard sorts that out; naming
# it here as well means the block below cannot depend on an import order.
{.emit: """#include "aowlspt_shim.h" """.}

# The same lock the other two hosts guard their queues with, for the same
# reason and out of the same file.
#
# "The simulator has one thread" is true of the simulator and not of the mod it
# is running. A mod is *told* to do its work on a worker thread and marshal
# back with `onMainThread`, which is `invoke_main`, which appends to `gTimers`
# -- from that worker thread, while this thread is walking the same sequence
# once a tick. `mods/sain` does exactly this and so does the pattern every
# per-frame mod is written to. Without a lock that is a torn sequence: a lost
# callback on a good day and a call through a freed function pointer on a bad
# one, with no diagnostic either way, which is the failure a simulator is least
# able to afford because the mod author will read it as their own bug.
#
# Held only around the sequence operations, never across a call into a mod:
# every list is snapshotted under the lock and walked outside it.
{.emit: """#include "aowlspt_lock.h" """.}

proc cLock() {.importc: "aowl_lock", nodecl.}
proc cUnlock() {.importc: "aowl_unlock", nodecl.}

## ---------------------------------------------------------------------------
## The three entries above the shared builder's watermark, and two OS calls
## ---------------------------------------------------------------------------
##
## `aowl_hostapi_new` fills the struct as far as revision 2 and says so, because
## revisions 3 and 4 need a managed heap and a detour engine. This host has
## neither, and it still must not report revision 2: a mod reads `size` to find
## out whether an entry is *there*, and there is a real difference between "the
## host does not have that function" and "the function is there and will tell
## you it cannot". The second is what every other unimplementable entry in this
## file does (`call`, `resolve`, `patch`), and `aowlspt_notify.h` does the same
## thing for the backend. So: fill them with the refusal, then raise `size`.
##
## Not shared with `aowlspt_notify.h` even though three of the four functions
## are identical, because that header also installs `notify_push` and names an
## `aowlspt_nim_notify_push` only the backend defines -- linking it here would
## mean defining a websocket entry point in a process with no socket.
{.emit: """
static AowlStatus AOWLSPT_CALL aowl_sim_no_pointer(void* ctx, AowlHandle h,
                                                   uint64_t* outAddress) {
    (void)ctx; (void)h;
    if (outAddress) *outAddress = 0;
    return AOWLSPT_ERR_UNSUPPORTED;
}
static AowlStatus AOWLSPT_CALL aowl_sim_no_pin(void* ctx, AowlHandle h,
                                               AowlHandle* outPinned) {
    (void)ctx; (void)h;
    if (outPinned) *outPinned = AOWLSPT_NULL_HANDLE;
    return AOWLSPT_ERR_UNSUPPORTED;
}
static AowlStatus AOWLSPT_CALL aowl_sim_no_patch_typed(
        void* ctx, AowlSlice target, int32_t kind,
        AowlTypedPatchFn handler, void* user) {
    (void)ctx; (void)target; (void)kind; (void)handler; (void)user;
    return AOWLSPT_ERR_UNSUPPORTED;
}
static void aowl_hostapi_arm_sim(void* p) {
    AowlHostBlock* b = (AowlHostBlock*)p;
    if (!b) return;
    b->api.handle_pointer = aowl_sim_no_pointer;
    b->api.handle_pin     = aowl_sim_no_pin;
    b->api.patch_typed    = aowl_sim_no_patch_typed;
    /* Last: the watermark rises only once everything under it is a pointer
     * somebody may call. */
    b->api.size           = AOWLSPT_HOSTAPI_SIZE_REV4;
}

/* Last-write time as one number. `--watch` compares it against itself; nothing
 * reads it as a date. */
static uint64_t aowl_sim_file_stamp(const char* path) {
    WIN32_FILE_ATTRIBUTE_DATA d;
    if (!path) return 0;
    if (!GetFileAttributesExA(path, GetFileExInfoStandard, &d)) return 0;
    return ((uint64_t)d.ftLastWriteTime.dwHighDateTime << 32) |
           (uint64_t)d.ftLastWriteTime.dwLowDateTime;
}

/* Ctrl+C under `--watch` has to unload rather than kill: a mod that stops its
 * threads in `on_unload` should get the chance, and the store should be closed
 * rather than left to the process teardown. */
static volatile LONG aowl_sim_stop = 0;
static BOOL WINAPI aowl_sim_on_ctrl(DWORD kind) {
    (void)kind;
    aowl_sim_stop = 1;
    return TRUE;
}
static void aowl_sim_arm_ctrl(void) { SetConsoleCtrlHandler(aowl_sim_on_ctrl, TRUE); }
static int32_t aowl_sim_stopping(void) { return (int32_t)aowl_sim_stop; }
""".}

proc cArmSim(hostBlock: HostPtr) {.importc: "aowl_hostapi_arm_sim", nodecl.}
proc cFileStamp(path: cstring): uint64 {.importc: "aowl_sim_file_stamp", nodecl.}
proc cArmCtrl() {.importc: "aowl_sim_arm_ctrl", nodecl.}
proc cStopping(): int32 {.importc: "aowl_sim_stopping", nodecl.}

# The route callback goes through `aowl_invoke_route` for the reason every
# other trampoline in the shim exists: an `AowlRouteFn` takes five parameters
# where an `AowlCallbackFn` takes three, and calling one through the other is a
# crash rather than a type error.
proc cInvokeRoute(cb, user, url: HostPtr; urlLen: int32;
                  body: HostPtr; bodyLen: int32;
                  session: HostPtr; sessionLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
  importc: "aowl_invoke_route", nodecl.}
proc cFreeBuf(p: HostPtr) {.importc: "aowl_host_release", nodecl.}

const
  HostName = "aowlspt-sim"
  HostVersion = "2.0.0"
    ## 1.x was the C# simulator, which stopped at ABI revision 1. A mod that
    ## logs the host it is on should be able to tell them apart.
  RouteDynamic = 1'i32
  SimSession = "000000000000000000000001"
    ## The session id handed to a `--route`. A MongoId, because that is what
    ## the backend refuses anything else for and a mod that parses one here
    ## should be parsing the same shape.

## ---------------------------------------------------------------------------
## Console
## ---------------------------------------------------------------------------

var gQuiet = false
var gErrors = 0

proc simLine(level, msg: string) =
  ## Every line this process prints, including the loader's own -- `modhost`
  ## calls this through `setLogSink`.
  ##
  ## The exit status is decided here rather than by any one call site: a
  ## simulator run "failed" exactly when something logged at error level,
  ## whether that was a mod's self-test, the loader, or a scheduled callback.
  let lv = strip(level)
  if lv == "error":
    inc gErrors
  if gQuiet and not (lv == "error" or lv == "warn"):
    return
  let stamp = fmtElapsed(int(elapsedMs()))
  var pad = level
  while pad.len < 5:
    pad.add ' '
  let text = "[" & stamp & "] " & pad & " " & msg
  # Flushed on every line, and stdout flushed before anything goes to stderr.
  # stdout is block-buffered when it is a pipe -- which is what `aowl test`
  # gives it -- while stderr is not, so without this a warning lands in the
  # middle of a line stdout had not got round to writing. The output was
  # mangled exactly when somebody was reading it to find out what went wrong.
  if lv == "error" or lv == "warn":
    flushFile(stdout)
    write(stderr, text & "\n")
    flushFile(stderr)
  else:
    echo text
    flushFile(stdout)

proc say(msg: string) = modhost.info msg
proc note(msg: string) = modhost.logLine("debug", msg)

proc usage() =
  write(stderr, """
aowlspt-sim -- run a native aowlspt mod with no game and no server

  aowlspt-sim <mod-dir-or-library> [options]

Options
  --ticks N               update ticks to run (default 3)
  --tick-ms N             milliseconds between ticks (default 16)
  --db FILE               JSON file served as the SPT database
  --stubs FILE            JSON map of "Type::Member" -> canned `call` result
  --route URL[,BODY]      invoke a registered route, print the response
  --emit NAME[,JSON]      publish an event after load
  --side server|client|sim  which side to present as (default sim).
                          client refuses db_get, db_patch and route_register,
                          exactly as the IL2CPP client host does
  --spt-version V         version to report as SPT's
  --store DIR             where the mod's store lives (default: a per-mod
                          directory under %TEMP%\aowlspt-sim)
  --watch                 reload the mod when its library changes
  --quiet                 only warnings and errors

Examples
  aowlspt-sim examples/hello
  aowlspt-sim examples/hello --side server --route /aowlspt/hello
  aowlspt-sim examples/hello --watch --ticks 0
""")

## ---------------------------------------------------------------------------
## What a mod registered
## ---------------------------------------------------------------------------

type
  Route = object
    url: string
    kind: int32
    cb: HostPtr
    user: HostPtr
    modIndex: int

  Sub = object
    name: string
    cb: HostPtr
    user: HostPtr
    modIndex: int

  Timer = object
    dueMs: int64
    cb: HostPtr
    user: HostPtr
    modIndex: int

var gRoutes: seq[Route] = @[]
var gSubs: seq[Sub] = @[]
var gTimers: seq[Timer] = @[]
## THREAD-LOCAL for the same reason as `aowlhost.nim`'s: a plain global string
## assigned from ABI entry points on more than one thread frees the previous
## buffer on whichever thread assigns, which is a cross-thread free and, when
## two threads race, a double free. That corrupted mimalloc's thread-free list
## in the IL2CPP host (measured 2026-09-03, WER dump EscapeFromTarkov.exe.636).
## The sim host is less exposed but the shape is identical, and a threadvar is
## also what makes `hostLastError`'s borrowed pointer honestly per-thread.
var gLastError {.threadvar.}: string
var gStubs = ""
var gStubFile = ""
var gSide = SideSim
var gModHome = ""
var gHandles: seq[string] = @[]
proc looksLikeJsonObject(text: string; why: var string): bool =
  ## Whether a document can be read at all, as distinct from whether it holds
  ## the key somebody asked for.
  ##
  ## Every JSON reader in this repo scans from byte zero and answers "no such
  ## key" for a document it could not parse, so without this test a truncated
  ## config, a stubs file that is a list rather than a map, and a database file
  ## that is a stray line of text all arrive at the mod as "what you asked for
  ## is not there" -- a sentence about the mod, when the true sentence is about
  ## the file.
  ##
  ## It used to be `strip(text)[0] == '{'`, which catches a BOM and a UTF-16
  ## save and nothing else. `jsonpath.jsonFault` is the real walk, shared with
  ## the two other hosts, and it says *where* -- so a `--db` file with a
  ## trailing comma is now refused with the offset instead of loaded and then
  ## silently half-read.
  var fault = ""
  if jsonFault(text, fault):
    why = fault
    return false
  why = ""
  result = true

proc clientRefusal(what, why: string; into: var string): bool =
  ## The three entries the IL2CPP client host refuses outright.
  ##
  ## `--side client` is a person saying "present as the client", and a
  ## simulator that then served a database and registered routes would be
  ## answering questions the real client host answers with
  ## `AOWLSPT_ERR_UNSUPPORTED` -- so a mod would be developed against a host
  ## that does not exist, and find out in a raid. The wording is the client
  ## host's own, with this host named, because the mod author needs to know
  ## which of the two refused.
  if gSide != SideClient:
    return false
  into = "aowlspt-sim is presenting as the client (--side client): " & why &
         ". The IL2CPP client host refuses " & what & " for the same reason; " &
         "run with --side server to use it."
  result = true

proc dropModRegistrations(index: int) =
  ## Everything the mod left here, before its library is freed. A route or a
  ## timer that outlives the library is a call through a function pointer into
  ## unmapped memory.
  ##
  ## Under the lock, and this is the site that most needs it: the mod being
  ## torn down may still have a worker thread that has not noticed, and one
  ## more `schedule` from it arriving in the middle of this rebuild would put a
  ## callback into a library that is about to be freed.
  cLock()
  var keptRoutes: seq[Route] = @[]
  for r in gRoutes:
    if r.modIndex != index: keptRoutes.add r
  gRoutes = keptRoutes

  var keptSubs: seq[Sub] = @[]
  for s in gSubs:
    if s.modIndex != index: keptSubs.add s
  gSubs = keptSubs

  var keptTimers: seq[Timer] = @[]
  for t in gTimers:
    if t.modIndex != index: keptTimers.add t
  gTimers = keptTimers
  cUnlock()

## ---------------------------------------------------------------------------
## The host API
## ---------------------------------------------------------------------------

proc levelTag(level: int32): string =
  case level
  of 0'i32: "trace"
  of 1'i32: "debug"
  of 3'i32: "ok   "
  of 4'i32: "warn "
  of 5'i32: "error"
  else: "info "

proc hostLog(ctx: HostPtr; level: int32; msg: HostPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  ## The guid goes in front of the message rather than into a column of its
  ## own: with several mods loaded, "which mod said this" is the first thing
  ## anyone reading the output wants, and it is the only source this host has.
  let text = readBytes(msg, len)
  let guid = modGuidOf(int(cast[uint](ctx)))
  modhost.logLine(levelTag(level),
                  (if guid.len > 0: guid & ": " & text else: text))

proc hostLastError(ctx: HostPtr; outPtr, outLen: HostPtr) {.
    exportc: "aowlspt_nim_last_error", cdecl.} =
  if gLastError.len == 0:
    discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
    return
  discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(gLastError)),
                   int32(gLastError.len))

proc hostConfigGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_config_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let idx = int(cast[uint](ctx))
  # This host was the only one that told a mod its config had failed to parse,
  # and it did so with `ErrGeneric` -- loud in the log, but a status a mod
  # cannot act on, since `ErrGeneric` is every unclassified failure there is.
  # `modhost.configRead` is the shared read now: `ErrConfigParse`, a message
  # naming the file and the fault, and the same once-per-mod warn line this
  # host already emitted. The other two hosts do exactly this, which is the
  # point -- a mod tested here behaves the same way in a raid.
  var text = ""
  var cfgErr = ""
  let cfgSt = configRead(idx, text, cfgErr)
  if cfgSt != StatusOk:
    gLastError = cfgErr
    # The whole document comes back even unparsed -- see the backend's copy of
    # this for why. This host used to withhold it, which is one more way the
    # three disagreed.
    if cfgSt == ErrConfigParse and k.len == 0 and text.len > 0:
      var raw = text
      discard cOutCopy(outPtr, outLen, cast[HostPtr](toCString(raw)),
                       int32(raw.len))
    return cfgSt
  var value = ""
  if k.len == 0:
    value = text
  elif not pathGet(text, k, value):
    gLastError = "no such key: " & k
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostConfigSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_config_set", cdecl.} =
  ## Refused for the reason the backend refuses it: `config.json` is a file a
  ## person edits, and a host that rewrites it while they have it open loses
  ## whichever copy is written second. The mod's own writable state is the
  ## store, which is right here.
  gLastError = "the simulator does not write mod config; " &
               "config.json is yours to edit and the store is the mod's"
  result = ErrUnsupported

proc hostDbGet(ctx: HostPtr; path: HostPtr; pathLen: int32;
               outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_db_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  var refusal = ""
  if clientRefusal("db_get", "the client has no database; db_get is " &
                   "server-side", refusal):
    gLastError = refusal
    return ErrUnsupported
  let p = readBytes(path, pathLen)
  var value = ""
  if not dbGetPath(p, value):
    gLastError = "no database entry at '" & p & "'" &
                 (if dbText().len <= 2: " (no --db file was given)" else: "")
    return ErrNotFound
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostDbPatch(ctx: HostPtr; path: HostPtr; pathLen: int32;
                 patch: HostPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  ## Creating the path is friendlier than refusing, and it is what the backend
  ## does: a mod adding a new item should not need the `--db` file to mention
  ## it already.
  var refusal = ""
  if clientRefusal("db_patch", "the client has no database; db_patch is " &
                   "server-side", refusal):
    gLastError = refusal
    return ErrUnsupported
  let p = readBytes(path, pathLen)
  let j = readBytes(patch, patchLen)
  var err = ""
  if not dbPatchPath(p, j, err):
    gLastError = err
    return ErrGeneric
  note "db patched " & p
  result = StatusOk

proc hostRouteRegister(ctx: HostPtr; url: HostPtr; urlLen: int32; kind: int32;
                       cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_route_register", cdecl.} =
  var refusal = ""
  if clientRefusal("route_register", "the client does not serve HTTP; routes " &
                   "are server-side", refusal):
    gLastError = refusal
    return ErrUnsupported
  let u = readBytes(url, urlLen)
  if u.len == 0 or cb == nil:
    gLastError = "a route needs a url and a handler"
    return ErrBadArg
  cLock()
  var clash = false
  for r in gRoutes:
    if r.url == u and r.kind == kind:
      clash = true
  if not clash:
    gRoutes.add Route(url: u, kind: kind, cb: cb, user: user,
                      modIndex: int(cast[uint](ctx)))
  cUnlock()
  if clash:
    gLastError = "the route " & u & " is already registered"
    return ErrGeneric
  note "route " & u & (if kind == RouteDynamic: " (prefix)" else: "")
  result = StatusOk

proc modGuarded(index: int): bool =
  ## Whether `index` names a row `modEnter` can speak about. The client host
  ## carries the same proc with the same comment on it: `modEnter` folds "out
  ## of range" and "draining" into one `false`, and a registration that came
  ## from something other than a mod -- there are none in this host today, and
  ## the other two have several -- must be dispatched to rather than skipped.
  ## `ModSlotLimit` is a constant so the enter and the leave cannot disagree
  ## about which case they are in.
  result = index >= 0 and index < modhost.ModSlotLimit

proc deliverEvent(n, body: string; fromIndex: int): int =
  ## The subscribers are taken under the lock and called outside it: a handler
  ## may subscribe, unsubscribe by unloading, or emit again, and none of those
  ## may run while this holds the list. A subscriber added during a delivery is
  ## therefore not called by that delivery, which is the same rule the two
  ## other hosts' drains follow.
  result = 0
  cLock()
  var due: seq[Sub] = @[]
  for i in 0 ..< gSubs.len:
    if gSubs[i].name == n and gSubs[i].modIndex != fromIndex:
      due.add gSubs[i]
  cUnlock()
  for s in due:
    # The same reference the backend and the client host take around a
    # subscriber, and it is the one place worth being honest about what it does
    # *here*: nothing, today. See the note on `runTimers` -- this host has one
    # dispatch thread and the unload runs on it, so `modEnter` can never refuse.
    # It is taken anyway because `s.cb` is a copied function pointer into a
    # mod's library exactly as it is in the other two hosts, and the only thing
    # standing between it and a `FreeLibrary` is that this host happens not to
    # have a second thread. That is a property of the loop, not of the ABI.
    let guard = modGuarded(s.modIndex)
    if guard and not modhost.modEnter(s.modIndex):
      continue
    var b = body
    let st = cInvokeCallback(s.cb, s.user,
                             cast[HostPtr](toCString(b)), int32(body.len))
    if guard:
      modhost.modLeave(s.modIndex)
    if st != StatusOk:
      modhost.warn "a subscriber to " & n & " returned " & $int(st)
    inc result

proc hostEmit(name, payload: string) =
  ## What `modcontrol` answers through. `-1` is not a mod index, so everybody
  ## hears it including the manager that asked.
  discard deliverEvent(name, payload, -1)

proc controlReply(name, payload: string) =
  ## The same, and printed on the way past.
  ##
  ## `modcontrol` answers a request by *emitting* an event, and an event with
  ## no subscriber reaches nobody -- so `--emit aowlspt.host.mods.list` from a
  ## terminal looked exactly like a request that had been dropped on the floor,
  ## whether it had been answered or not. The manager is the mod developed
  ## against this host, and the answer it would have received is the one thing
  ## a person driving the protocol by hand has to see.
  modhost.info "host -> " & name & " " & payload
  hostEmit(name, payload)

proc hostEventEmit(ctx: HostPtr; name: HostPtr; nameLen: int32;
                   payload: HostPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_event_emit", cdecl.} =
  let n = readBytes(name, nameLen)
  let body = readBytes(payload, payloadLen)
  let from1 = int(cast[uint](ctx))
  # Recorded here and performed from the tick loop, never here: this stack runs
  # through the mod that emitted, and an unload would free the library it is
  # about to return into.
  let control = modcontrol.submit(n, body)
  let delivered = deliverEvent(n, body, from1)
  if delivered == 0 and not control:
    note "event " & n & " (no subscribers)"
  result = StatusOk

proc hostEventSubscribe(ctx: HostPtr; name: HostPtr; nameLen: int32;
                        cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  let n = readBytes(name, nameLen)
  if n.len == 0 or cb == nil:
    gLastError = "a subscription needs a name and a handler"
    return ErrBadArg
  cLock()
  gSubs.add Sub(name: n, cb: cb, user: user, modIndex: int(cast[uint](ctx)))
  cUnlock()
  note "subscribed to " & n
  result = StatusOk

proc stubFor(target: string; into: var string): bool =
  ## A stub by its written name, or by the type a handle came from -- so a
  ## fixture can be written against `"Type::Member"` and still answer the
  ## `"#3::Member"` form a resolved handle produces.
  into = ""
  if gStubs.len == 0:
    return false
  if jsonGet(gStubs, target, into):
    return true
  if target.len < 2 or target[0] != '#':
    return false
  let split = find(target, "::")
  if split <= 1:
    return false
  var h = 0
  if not parseInt32(target.substr(1, split - 1), h):
    return false
  cLock()
  var owner = ""
  if h >= 1 and h <= gHandles.len:
    owner = gHandles[h - 1]
  cUnlock()
  if owner.len == 0:
    return false
  result = jsonGet(gStubs, owner & target.substr(split), into)

proc hostCall(ctx: HostPtr; target: HostPtr; targetLen: int32;
              args: HostPtr; argsLen: int32;
              outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_call", cdecl.} =
  ## Scripted or refused, and never guessed at.
  ##
  ## `--stubs` is a person writing down what a real host would have answered
  ## for one named target, which is a test fixture. Everything else is a mod
  ## reaching for a managed runtime that is not in this process, and the only
  ## honest answer to that is the one the backend gives.
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let t = readBytes(target, targetLen)
  var canned = ""
  if stubFor(t, canned):
    var v = canned
    return cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))
  # Which of the two "no stub" situations this is, because they need different
  # things done: one is a file to write, the other is a line to add to a file
  # that is already being read. Naming the file also settles the third
  # possibility, which is that the file the author is editing is not the file
  # this run was given.
  gLastError = "the simulator has no managed runtime to reflect into, and " &
               (if gStubFile.len == 0:
                  "no --stubs file was given, so there is nothing here to " &
                  "answer '" & t & "' with. Put \"" & t & "\": <json> in a " &
                  "file and pass --stubs FILE."
                else:
                  "'" & t & "' is not named in " & gStubFile & ". Add \"" &
                  t & "\": <json> to it to script this call.")
  result = ErrUnsupported

proc hostResolve(ctx: HostPtr; typeName: HostPtr; nameLen: int32;
                 outHandle: HostPtr): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  ## A name table, and the one place this host answers something it cannot
  ## check. That deserves saying plainly.
  ##
  ## `resolve` names a *type*, not an object, and every host answers it by
  ## asking a runtime whether that type exists. There is no runtime here, so
  ## the truthful answer is "I do not know", and the ABI has no code for that
  ## -- only `AOWLSPT_ERR_UNSUPPORTED`, which a mod reads as "no such type".
  ##
  ## Refusing was tried and it is the wrong answer, for a reason `mods/perf`
  ## demonstrates: a mod resolves its types at load and does everything else
  ## behind that gate, so a host that refuses `resolve` makes every rule past
  ## it -- `mods/perf` checks that an out-of-band knob value is refused rather
  ## than clamped, which is pure arithmetic -- untestable outside a game. The
  ## refusal would not be catching a bug; it would be hiding twenty checks.
  ##
  ## So the handle is issued, and it is issued *unusable*: the only thing the
  ## ABI lets a mod do with one is `call`, and `call` above refuses anything a
  ## person has not written into `--stubs`. Nothing here invents a value, a
  ## field or a firing. What is granted is the name -- and `handle_pointer`,
  ## the one entry that would turn a name into an address, refuses too.
  let n = readBytes(typeName, nameLen)
  if n.len == 0 or outHandle == nil:
    gLastError = "resolve needs a type name"
    return ErrBadArg
  # Under the lock: a mod may resolve its types from a worker thread, and the
  # handle it is given is this sequence's length.
  cLock()
  gHandles.add n
  var h = uint64(gHandles.len)
  cUnlock()
  copyMem(outHandle, addr h, 8)
  note "resolve " & n & " -> #" & $int(h)
  result = StatusOk

proc hostHandleRelease(ctx: HostPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  ## The name is cleared, the slot is kept: handles are indexes into this
  ## sequence and compacting it would silently repoint every live one at its
  ## neighbour.
  let i = int(handle)
  cLock()
  if i >= 1 and i <= gHandles.len:
    gHandles[i - 1] = ""
  cUnlock()

proc hostPatch(ctx: HostPtr; target: HostPtr; targetLen: int32; kind: int32;
               cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  let t = readBytes(target, targetLen)
  gLastError = "there is no compiled game code in the simulator to patch, so " &
               "'" & t & "' cannot be hooked here"
  result = ErrUnsupported

proc hostNowMs(ctx: HostPtr): int64 {.exportc: "aowlspt_nim_now_ms", cdecl.} =
  result = elapsedMs()

proc hostInvokeMain(ctx: HostPtr; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_invoke_main", cdecl.} =
  ## Queued rather than run where it stands, and that is the honest model: the
  ## simulator has exactly one thread and it pumps this queue once a tick, so a
  ## mod that marshals work onto "the main thread" sees the same one-tick delay
  ## it would see in a game.
  if cb == nil:
    gLastError = "invoke_main needs a callback"
    return ErrBadArg
  # Under the lock, because *this* is the entry a mod is told to call from a
  # worker thread. See the lock note at the top of the file.
  cLock()
  gTimers.add Timer(dueMs: elapsedMs(), cb: cb, user: user,
                    modIndex: int(cast[uint](ctx)))
  cUnlock()
  result = StatusOk

proc hostSchedule(ctx: HostPtr; delayMs: int32; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  if cb == nil:
    gLastError = "a timer needs a callback"
    return ErrBadArg
  var d = int64(delayMs)
  if d < 0: d = 0
  cLock()
  gTimers.add Timer(dueMs: elapsedMs() + d, cb: cb, user: user,
                    modIndex: int(cast[uint](ctx)))
  cUnlock()
  result = StatusOk

proc runTimers() =
  ## Due timers, one pass. The list is rebuilt rather than edited in place: a
  ## callback may schedule another timer, and appending to a sequence being
  ## walked by index is how that becomes a lost timer or a fired-twice one.
  ##
  ## The split happens under the lock and the firing outside it, which is what
  ## makes `everyMain` a per-frame callback rather than a spin: a callback that
  ## queues itself again lands in the sequence this pass has already left
  ## behind, so it is picked up by the next drain and not by this one. The two
  ## other hosts arrange their drains the same way and `aowlspt.everyMain`
  ## depends on all three doing it.
  let now = elapsedMs()
  cLock()
  var due: seq[Timer] = @[]
  var keep: seq[Timer] = @[]
  for t in gTimers:
    if t.dueMs <= now: due.add t
    else: keep.add t
  if due.len > 0:
    gTimers = keep
  cUnlock()
  if due.len == 0:
    return
  for t in due:
    # **Where this host differs.** In the client host the matching loop is the
    # real race: its drain runs on Unity's main thread while `unloadOne` runs on
    # the host's tick thread, so a callback lifted out of the queue can be
    # called after the library it lives in has been freed. Here there is one
    # thread. `runTimers`, `deliverEvent`, `invokeRoute`, `modcontrol.drain`
    # (which is what performs an unload) and `tickMods` all run from `drainWork`
    # and the tick loop on the process's main thread, in that order, and an
    # unload requested from inside a callback is only *recorded* there and
    # performed by a later `modcontrol.drain`. So nothing is ever in flight when
    # `drainMod` reads the count, and this `modEnter` cannot refuse.
    #
    # Kept because a guard that costs 11 ns on a path that ticks at `--tick-ms`
    # is not worth reasoning about, and because the sole thing making it
    # unnecessary is the shape of this loop -- the moment the simulator grows a
    # second thread that dispatches (a real HTTP listener has been discussed for
    # `invokeRoute`), the absence would be a silent use-after-free rather than a
    # compile error. The other two hosts carry the pair; drift between them is
    # how this class of bug came back twice already.
    let guard = modGuarded(t.modIndex)
    if guard and not modhost.modEnter(t.modIndex):
      continue
    discard cInvokeCallback(t.cb, t.user, cast[HostPtr](0), 0'i32)
    if guard:
      modhost.modLeave(t.modIndex)

# --------------------------------------------------------------- store

proc hostStoreGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let k = readBytes(key, keyLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var value = ""
  var error = ""
  let got = storeReadInto(guid, k, value, error)
  if got != ReadOk:
    gLastError = error
    if got == ReadMissing:
      return ErrNotFound
    # Present and unreadable is deliberately not `ErrNotFound`: a mod that
    # cannot tell the two apart answers "your profile is unreadable" by making
    # a new one over the top of it.
    if got == ReadFailed:
      modhost.fail "store read failed: " & error
    return ErrGeneric
  var v = value
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc hostStoreSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_store_set", cdecl.} =
  let k = readBytes(key, keyLen)
  let v = readBytes(val, valLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var error = ""
  if not storeWrite(guid, k, v, error):
    gLastError = error
    return ErrGeneric
  if error.len > 0:
    note "store: " & error
  result = StatusOk

proc hostStoreList(ctx: HostPtr; prefix: HostPtr; prefixLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_list", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  let p = readBytes(prefix, prefixLen)
  let guid = modGuidOf(int(cast[uint](ctx)))
  if guid.len == 0:
    gLastError = "no such mod context"
    return ErrBadArg
  var v = storeKeys(guid, p)
  result = cOutCopy(outPtr, outLen, cast[HostPtr](toCString(v)), int32(v.len))

proc patchFired(slot: int32; regs: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Nothing here can fire: `patch` is refused outright above. It exists
  ## because the shim declares the symbol and zero means "run the original",
  ## which is the only safe answer for a slot that cannot exist.
  result = 0'i32

## ---------------------------------------------------------------------------
## Driving a route
## ---------------------------------------------------------------------------

proc findRoute(url: string): int =
  ## Called with the lock held; the caller copies the row out before it lets
  ## go, because an index into a sequence another thread may append to is only
  ## an index for as long as nobody does.
  result = -1
  for i in 0 ..< gRoutes.len:
    if cmpIgnoreCase(gRoutes[i].url, url) == 0:
      return i
  # A dynamic route matches by prefix, the same way the backend's router does,
  # so a url carrying parameters reaches its handler.
  for i in 0 ..< gRoutes.len:
    if gRoutes[i].kind == RouteDynamic and
       startsWith(toLowerAscii(url), toLowerAscii(gRoutes[i].url)):
      return i

proc noRouteReason(url: string): string =
  ## Why a `--route` found nothing, in the terms the author has to act on.
  ##
  ## "no route registered for X" is true and unhelpful in the case that
  ## actually happens: the mod registers its routes behind a `side()` guard --
  ## every server mod does, because the client host refuses `route_register` --
  ## and the run defaulted to `--side sim`, so the guard never fired. The url
  ## was never wrong. Saying what *is* registered, and on which side this run
  ## is, is the difference between a typo hunt and a one-word fix.
  result = "no route registered for '" & url & "'"
  cLock()
  if gRoutes.len == 0:
    result.add "; this mod registered no routes at all on the " &
               sideName(gSide) & " side"
    if gSide != SideServer:
      result.add ". Routes are server-side -- a mod that guards its " &
                 "registration with side() registers none here. Try " &
                 "--side server."
  else:
    result.add "; the " & $gRoutes.len & " route(s) this mod registered are:"
    for r in gRoutes:
      result.add " " & r.url & (if r.kind == RouteDynamic: "*" else: "")
  cUnlock()

proc invokeRoute(url, body: string; into: var string): bool =
  into = ""
  cLock()
  let idx = findRoute(url)
  var hitCb: HostPtr = cast[HostPtr](0)
  var hitUser: HostPtr = cast[HostPtr](0)
  var hitMod = -1
  if idx >= 0:
    hitCb = gRoutes[idx].cb
    hitUser = gRoutes[idx].user
    hitMod = gRoutes[idx].modIndex
  cUnlock()
  if idx < 0:
    return false
  # The backend takes this around `runRoute` and for the same reason: the route
  # was copied out from under the lock and the copy is a function pointer into
  # the mod. Uncontended here -- see `runTimers` for why this host cannot race
  # itself -- and a refusal is reported as "no such route", which is the only
  # answer this caller has and the honest one for a mod on its way out.
  let guard = modGuarded(hitMod)
  if guard and not modhost.modEnter(hitMod):
    return false
  var u = url
  var b = body
  var s = SimSession
  var outPtr: HostPtr = cast[HostPtr](0)
  var outLen = 0'i32
  let st = cInvokeRoute(hitCb, hitUser,
                        cast[HostPtr](toCString(u)), int32(u.len),
                        cast[HostPtr](toCString(b)), int32(b.len),
                        cast[HostPtr](toCString(s)), int32(s.len),
                        cast[HostPtr](addr outPtr), cast[HostPtr](addr outLen))
  if outPtr != nil and outLen > 0'i32:
    into = readBytes(outPtr, outLen)
  if outPtr != nil:
    cFreeBuf(outPtr)
  # Given back before either return: a reference leaked here is an unload that
  # times out after five seconds and a mod that can never come off again.
  if guard:
    modhost.modLeave(hitMod)
  if st != StatusOk:
    modhost.fail url & " returned " & $int(st) & ": " & gLastError
    return true
  result = true

## ---------------------------------------------------------------------------
## Options
## ---------------------------------------------------------------------------

type
  Options = object
    target: string
    ticks: int
    tickMs: int32
    dbFile: string
    stubFile: string
    storeDir: string
    sptVersion: string
    side: int32
    watch: bool
    routes: seq[string]
    bodies: seq[string]
    emits: seq[string]
    payloads: seq[string]

proc splitOnce(value: string; head, tail: var string) =
  ## `--route /url,{"body":1}` -- the *first* comma separates the two, so a
  ## JSON body full of commas survives intact.
  let comma = find(value, ",")
  if comma < 0:
    head = value
    tail = ""
  else:
    head = value.substr(0, comma - 1)
    tail = value.substr(comma + 1)

proc parseInt32(text: string; into: var int): bool =
  var v = 0
  var any = false
  for ch in text:
    if ch < '0' or ch > '9':
      return false
    v = v * 10 + (ord(ch) - ord('0'))
    any = true
  if not any:
    return false
  into = v
  result = true

proc libraryIn(dir, stem: string; why: var string): string =
  ## The built layout (`<mod>/bin/<mod>.dll`) and a flat one, then a single
  ## `.dll` in either place. A directory with two is ambiguous and is refused
  ## rather than guessed at -- and `why` carries the refusal, because "no mod
  ## library found" in front of a directory holding two of them is a false
  ## statement that sends the author looking for a build that already ran.
  why = ""
  var probe = joinPath(joinPath(dir, "bin"), stem & ".dll")
  if fileExists(probe):
    return probe
  probe = joinPath(dir, stem & ".dll")
  if fileExists(probe):
    return probe
  var roots: seq[string] = @[joinPath(dir, "bin"), dir]
  for root in roots:
    if not isDirectory(root):
      continue
    var files: seq[string] = @[]
    var dirs: seq[string] = @[]
    collectEntries(root, files, dirs)
    var found = ""
    var names = ""
    var count = 0
    for f in files:
      # `collectEntries` walks down; a library in a subdirectory is a
      # dependency of the mod rather than the mod, so only this level counts.
      if find(f, "\\") >= 0 or find(f, "/") >= 0:
        continue
      if endsWith(toLowerAscii(f), ".dll"):
        inc count
        found = joinPath(root, f)
        if names.len > 0: names.add ", "
        names.add f
    if count == 1:
      return found
    if count > 1:
      why = root & " holds " & $count & " libraries (" & names & ") and none " &
            "of them is named " & stem & ".dll, so which one is the mod is a " &
            "guess. Name the library outright: aowlspt-sim " &
            joinPath(root, "<one-of-those>.dll")
      return ""
  result = ""

proc resolveTarget(target: string; home, lib, why: var string): bool =
  ## `home` is what the mod is told its directory is, `lib` is what is loaded.
  ## They differ in a source tree, which is the only place this runs.
  home = ""
  lib = ""
  why = ""
  if target.len == 0:
    return false
  let full = absolutePathOf(target)
  if isDirectory(full):
    home = full
    lib = libraryIn(full, baseName(full), why)
    if lib.len == 0 and why.len == 0:
      why = "no mod library under " & full & ": expected " &
            joinPath(joinPath(full, "bin"), baseName(full) & ".dll") &
            ". Build it first with: aowl build-mod " & full
    return lib.len > 0
  if fileExists(full):
    lib = full
    # `<mod>/bin/<mod>.dll` names its mod directory one level up; anything else
    # sits in the directory it belongs to.
    let parent = parentOf(full)
    home = (if baseName(parent) == "bin": parentOf(parent) else: parent)
    return true
  why = "there is no file or directory at " & full
  result = false

## ---------------------------------------------------------------------------
## The run
## ---------------------------------------------------------------------------

proc defaultStoreDir(home: string): string =
  ## Per mod, under the user's temp directory, and it **persists between runs**
  ## on purpose: "save, exit, come back and still have it" is the single most
  ## common thing a mod's store is for, and a store wiped every run cannot show
  ## it. `--store` puts it somewhere else; deleting the directory resets it.
  ##
  ## Not inside the mod's own directory, which is a source tree here and would
  ## acquire an untracked `store/` per mod the first time anything saved.
  var base = getEnv("TEMP", "")
  if base.len == 0:
    base = getEnv("TMP", "")
  if base.len == 0:
    base = home
  result = joinPath(joinPath(base, "aowlspt-sim"), baseName(home))

proc shadowOf(storeDir, lib: string; into: var string): bool =
  ## A copy of the library, for `--watch` and only for `--watch`.
  ##
  ## Windows locks a mapped DLL: while the simulator holds the file you built,
  ## the next build cannot write over it and fails with a sharing violation.
  ## Loading a copy is what leaves the original writable, and is therefore the
  ## whole of what makes rebuild-and-reload possible -- the C# simulator did
  ## the same thing for the same reason.
  ##
  ## Not done for an ordinary run, deliberately. Without it the module a
  ## debugger attaches to is the file you built, which is what you want when
  ## you are stepping through it; the two nimony hosts behave that way as well.
  into = ""
  let dir = joinPath(storeDir, "shadow")
  let mk = ensureDir(dir)
  if not mk.ok:
    return false
  let dst = joinPath(dir, baseName(lib))
  let cp = copyFileAt(lib, dst)
  if not cp.ok:
    return false
  into = dst
  result = true

proc drainWork() =
  ## One pass of everything the host owes: due timers, then any mod-control
  ## request a mod emitted. Both are off the emitting stack by construction.
  runTimers()
  modcontrol.drain()

proc startMod(o: Options; lib: string): bool =
  result = modhost.loadMod(lib, o.side, HostName, HostVersion,
                           o.sptVersion, "", gModHome)

proc reportSelection(side: int32) =
  ## What an *installed* host would have done with this mod, which is not what
  ## this one does.
  ##
  ## The simulator loads the mod it was pointed at, always, and that is the
  ## right contract for a tool whose whole argument is `<mod>`. But the backend
  ## and the client host walk a mods directory and honour
  ## `aowlspt-selection.json`, so a mod switched off in the manager does not
  ## load there at all -- and the author who has just watched it run here would
  ## have no reason to suspect it. This says the difference out loud, and only
  ## when there is a difference to say: a selection that is absent, is for
  ## another side, or names this mod prints nothing.
  ##
  ## Read from the mod's parent directory, which is `mods\` for an installed
  ## layout and for this repository's tree alike. A mod somewhere else has no
  ## selection near it and this stays silent.
  let modsDir = parentOf(gModHome)
  if modsDir.len == 0:
    return
  var wanted: seq[string] = @[]
  let sel = readSelection(modsDir, side, wanted)
  case sel
  of srAbsent, srOtherSide:
    discard
  of srUnusable:
    modhost.warn "there is a selection file next to this mod that cannot be " &
                 "acted on (" & selectionNote() & "). It does not affect this " &
                 "run -- the simulator loads the mod you named -- but the " &
                 "backend and the client host would have to fall back to " &
                 "loading everything installed."
  of srHonoured:
    let guid = modGuidOf(modCount() - 1)
    var named = false
    for id in wanted:
      if id == guid: named = true
    if not named:
      modhost.warn guid & " is not in " & selectionNote() & ", which names " &
                   $wanted.len & " mod(s). It ran here because the simulator " &
                   "loads the mod you name; a host that walks a mods " &
                   "directory would not have loaded it at all."

proc main(): int =
  let n = paramCount()
  if n < 1:
    usage()
    return 2
  let first = paramStr(1)
  if first == "-h" or first == "--help":
    usage()
    return 0

  var o = Options(target: first, ticks: 3, tickMs: 16'i32, dbFile: "",
                  stubFile: "", storeDir: "", sptVersion: "", side: SideSim,
                  watch: false, routes: @[], bodies: @[], emits: @[],
                  payloads: @[])

  var i = 2
  while i <= n:
    let a = paramStr(i)
    if a == "--ticks" or a == "--tick-ms":
      inc i
      if i > n:
        write(stderr, "aowlspt-sim: " & a & " needs a value\n")
        return 2
      var v = 0
      if not parseInt32(paramStr(i), v):
        write(stderr, "aowlspt-sim: " & a & " needs a number, got '" &
                      paramStr(i) & "'\n")
        return 2
      if a == "--ticks": o.ticks = v
      else: o.tickMs = int32(v)
    elif a == "--db" or a == "--stubs" or a == "--spt-version" or
         a == "--store" or a == "--side" or a == "--route" or a == "--emit":
      inc i
      if i > n:
        write(stderr, "aowlspt-sim: " & a & " needs a value\n")
        return 2
      let v = paramStr(i)
      if a == "--db": o.dbFile = v
      elif a == "--stubs": o.stubFile = v
      elif a == "--spt-version": o.sptVersion = v
      elif a == "--store": o.storeDir = v
      elif a == "--side":
        if v == "server": o.side = SideServer
        elif v == "client": o.side = SideClient
        elif v == "sim": o.side = SideSim
        else:
          write(stderr, "aowlspt-sim: unknown side '" & v & "'\n")
          return 2
      elif a == "--route":
        var head = ""
        var tail = ""
        splitOnce(v, head, tail)
        o.routes.add head
        o.bodies.add tail
      else:
        var head = ""
        var tail = ""
        splitOnce(v, head, tail)
        o.emits.add head
        o.payloads.add tail
    elif a == "--watch":
      o.watch = true
    elif a == "--quiet":
      gQuiet = true
    elif a == "-h" or a == "--help":
      usage()
      return 0
    else:
      write(stderr, "aowlspt-sim: unknown option '" & a & "'\n")
      return 2
    inc i

  var lib = ""
  var whyNoLib = ""
  if not resolveTarget(o.target, gModHome, lib, whyNoLib):
    write(stderr, "aowlspt-sim: " &
                  (if whyNoLib.len > 0: whyNoLib
                   else: "no mod library found at '" & o.target & "'") & "\n")
    return 2

  gSide = o.side
  startClock()
  setLogSink(simLine)

  # The database, always loaded even when there is no file: `db_patch` creates
  # the paths it is given, and a mod seeding a table it then reads back should
  # work here without anybody writing a db file first.
  # A file named on the command line that cannot be used stops the run rather
  # than being warned about and skipped. Warned-and-skipped was the old
  # behaviour and it is the shape of bug this whole file is arranged against:
  # every `db_get` afterwards answers "no database entry at ...", every `call`
  # answers "no stub for ...", and both sentences describe the mod. Somebody
  # who typed `--db` wants the database, so not having it is a refusal.
  var dbText = "{}"
  var whyBad = ""
  if o.dbFile.len > 0:
    var text = ""
    if not readTextFile(o.dbFile, text):
      write(stderr, "aowlspt-sim: --db file cannot be read: " & o.dbFile & "\n")
      return 2
    elif strip(text).len == 0:
      write(stderr, "aowlspt-sim: --db file is empty: " & o.dbFile &
                    "\n  An empty file is not an empty database; running " &
                    "without --db is.\n")
      return 2
    elif not looksLikeJsonObject(text, whyBad):
      write(stderr, "aowlspt-sim: --db file does not read as a JSON object: " &
                    o.dbFile & " (" & $text.len & " bytes)\n  " & whyBad &
                    ".\n  The database " &
                    "is one object of tables. Every db_get would answer 'no " &
                    "such entry' against this, which would read as the mod " &
                    "asking for the wrong path.\n")
      return 2
    else:
      dbText = text
      say "database loaded from " & o.dbFile & " (" & $text.len & " bytes)"
  dbLoad(dbText)

  if o.stubFile.len > 0:
    var text = ""
    if not readTextFile(o.stubFile, text):
      write(stderr, "aowlspt-sim: --stubs file cannot be read: " & o.stubFile &
                    "\n")
      return 2
    elif not looksLikeJsonObject(text, whyBad):
      write(stderr, "aowlspt-sim: --stubs file does not read as a JSON " &
                    "object: " & o.stubFile & " (" & $text.len & " bytes)\n" &
                    "  " & whyBad & ".\n" &
                    "  It is a map of \"Type::Member\" to the JSON that call " &
                    "should answer. Nothing in it could be found, and every " &
                    "call would be refused as though no stub had been " &
                    "written.\n")
      return 2
    else:
      gStubs = text
      gStubFile = o.stubFile
      say "call stubs loaded from " & o.stubFile

  var storeDir = o.storeDir
  if storeDir.len == 0:
    storeDir = defaultStoreDir(gModHome)
  storeInit(storeDir)
  # The directory is made here rather than left to the first write, so that a
  # store which cannot exist is a refusal at the top instead of a mod being
  # told, for the whole run, that it has nothing saved. "Nothing saved" is a
  # legitimate answer -- it is what a first run gets -- so a mod cannot tell it
  # apart from a store that was never there, and a mod whose self-test is
  # "write it, read it back" would report its own failure.
  let mkStore = ensureDir(storeRoot())
  if not mkStore.ok:
    write(stderr, "aowlspt-sim: the store directory cannot be created: " &
                  storeRoot() & " (error " & $int(mkStore.err) & ")\n" &
                  "  Every store_get would answer 'nothing saved', which is " &
                  "what a first run answers, so nothing would say the store " &
                  "was missing. Pass --store DIR somewhere writable.\n")
    return 2
  note "store " & storeRoot()
  var holder = ""
  var lockError = ""
  if not storeLock("sim", holder, lockError):
    # A warning rather than a refusal, which is the opposite of the backend's
    # answer and right for the opposite reason: two servers writing one
    # player's profile is data loss, two simulator runs over a scratch
    # directory is somebody running the gate twice.
    modhost.warn lockError & "; carrying on anyway"

  setModTeardown(dropModRegistrations)
  cArmCtrl()

  # The one entry `aowl_hostapi_new` cannot fill, through the seam the client
  # host already uses for the two it fills.
  setHostBlockArm(cArmSim)

  proc opsCount(): int = modhost.modCount()
  proc opsGuid(ix: int): string = modhost.modGuidOf(ix)
  proc opsName(ix: int): string = modhost.modNameOf(ix)
  proc opsVersion(ix: int): string = modhost.modVersionOf(ix)
  proc opsPath(ix: int): string = modhost.modPathOf(ix)
  proc opsLive(ix: int): bool = modhost.modIsLive(ix)
  proc opsFlags(ix: int): uint32 = modhost.modFlagsOf(ix)
  proc opsIndex(guid: string): int = modhost.modIndexOf(guid)
  proc opsCanUnload(ignored: int): bool = modhost.hasTeardown()
  proc opsLoad(path: string): bool =
    modhost.loadOne(path, gSide, HostName, HostVersion)
  proc opsUnload(guid: string): string =
    var err = ""
    if modhost.unloadByGuid(guid, err):
      return ""
    result = (if err.len > 0: err else: "the host refused to unload it")
  proc opsLog(msg: string) = modhost.info msg

  modcontrol.controlInit(HostName, HostVersion, o.side, controlReply,
                         HostOps(count: opsCount, guidOf: opsGuid,
                                 nameOf: opsName, versionOf: opsVersion,
                                 pathOf: opsPath, liveOf: opsLive,
                                 flagsOf: opsFlags, indexOf: opsIndex,
                                 canUnload: opsCanUnload, load: opsLoad,
                                 unload: opsUnload, log: opsLog,
                                 hotOf: nil, quiesce: nil, released: nil))
  ## `hotOf: nil` and `quiesce: nil` are the SIMULATOR's answer and not an
  ## oversight. There is no game here to be mid-teardown, and the whole value of
  ## `--watch` is reloading a mod that has not been written to be reloadable yet
  ## -- gating on the flag would refuse every mod in the repository, since none
  ## declares it. The client sets both; see `opsHot` in `aowlhost.nim`.

  # Under `--watch`, and only under `--watch`, what is loaded is a copy. See
  # `shadowOf`: the file you are editing has to stay writable, and it cannot
  # while this process has it mapped.
  var loadLib = lib
  if o.watch:
    var shadow = ""
    if not shadowOf(storeDir, lib, shadow):
      write(stderr, "aowlspt-sim: could not take a copy of " & baseName(lib) &
                    " to watch\n")
      return 1
    loadLib = shadow

  if not startMod(o, loadLib):
    # The reason is a line the loader already printed -- "does not support the
    # <side> side", "was built against ABI version N", "does not export the
    # aowlspt entry points". Under `--quiet` that line is an `info` and was
    # filtered out, leaving only this sentence, so `--quiet` is named here
    # rather than leaving the run with no reason in it at all.
    write(stderr, "aowlspt-sim: the mod did not load" &
                  (if gQuiet: "; the loader's reason was logged at info level " &
                              "and --quiet dropped it. Run again without " &
                              "--quiet.\n"
                   else: " -- see the line above for which step refused.\n"))
    storeClose()
    storeUnlock()
    return 1
  reportSelection(o.side)
  drainWork()

  for k in 0 ..< o.emits.len:
    say "emit " & o.emits[k]
    # Through `hostEmit`, not `hostEventEmit`: this event comes from the
    # command line rather than from a mod, so nobody is the emitter and nobody
    # is skipped. A control name is submitted too, so `--emit
    # aowlspt.host.mods.list` asks this host what it has loaded.
    discard modcontrol.submit(o.emits[k], o.payloads[k])
    hostEmit(o.emits[k], o.payloads[k])
    drainWork()

  for k in 0 ..< o.routes.len:
    var response = ""
    if not invokeRoute(o.routes[k], o.bodies[k], response):
      modhost.fail noRouteReason(o.routes[k])
    else:
      modhost.okLog o.routes[k] & " -> " & response
    drainWork()

  var previous = elapsedMs()
  for k in 0 ..< o.ticks:
    cSysSleep(o.tickMs)
    let now = elapsedMs()
    tickMods(now - previous)
    previous = now
    drainWork()

  if o.watch:
    var p = lib
    say "watching " & baseName(lib) & " -- Ctrl+C to stop"
    # Said once, at the top, because it is a property of the reload rather than
    # of any particular one, and because a mod author who has just rebuilt is
    # about to draw a conclusion from what the reloaded mod prints.
    #
    # **Nothing in memory crosses a reload here.** The ABI has `state_save` and
    # `state_load`, and `AOWLSPT_MOD_HOT_RELOADABLE` says a mod implements
    # them -- but no host in this repository calls either one yet, this one
    # included: the shared loader (`host/common/modhost.nim`) has no path to
    # them and the shim exports no accessor for the two entries. So a reload is
    # `on_unload`, `FreeLibrary`, `LoadLibrary`, `on_load` -- a cold start
    # against a warm store. Counters kept in globals restart; counters kept in
    # the store carry on, and a mod that keeps its run count in the store will
    # show it going *up* on a reload, which looks like state crossing and is
    # the opposite.
    say "a reload restarts the mod: no host calls state_save/state_load yet, " &
        "so nothing in the mod's memory crosses it. The store is the only " &
        "thing that survives, and it survives because it is on disk."
    var lastStamp = cFileStamp(toCString(p))
    let guid = modGuidOf(0)
    # `1'u32` rather than `modhost.ModHotReloadable`, which is
    # AOWLSPT_MOD_HOT_RELOADABLE and is that value: an imported `const` arrives
    # untyped, `and` then has no overload to pick, and giving it a type through
    # a local crashes the compiler in `semLocalValue`. Written out with the
    # name in this comment so a search for either one finds the other.
    let hotFlagged = (modFlagsOf(0) and 1'u32) != 0'u32
    if hotFlagged:
      modhost.warn modNameOf(0) & " declares AOWLSPT_MOD_HOT_RELOADABLE, so " &
                   "it expects stateSave/stateLoad to carry it across a " &
                   "reload. They will not be called here -- no host " &
                   "implements them yet -- so its stateLoad never runs and it " &
                   "comes back in its initial state."
    var shadow = ""
    while cStopping() == 0'i32:
      cSysSleep(o.tickMs)
      let now = elapsedMs()
      tickMods(now - previous)
      previous = now
      drainWork()

      let stamp = cFileStamp(toCString(p))
      if stamp == lastStamp or stamp == 0'u64:
        continue
      # A build writes in chunks; wait for the file to stop changing rather
      # than loading half a DLL.
      cSysSleep(250'i32)
      if cFileStamp(toCString(p)) != stamp:
        continue
      lastStamp = stamp
      var err = ""
      if not unloadByGuid(guid, err):
        modhost.warn "could not unload before reloading: " & err
        drainWork()
        continue
      # A fresh copy of what was just built, for the same reason the first one
      # was a copy.
      if not shadowOf(storeDir, lib, shadow):
        modhost.fail "could not take a copy of " & baseName(lib) &
                     "; the mod is unloaded and this run cannot continue"
        break
      if not modhost.loadOne(shadow, o.side, HostName, HostVersion,
                             o.sptVersion, "", gModHome):
        modhost.fail "the rebuilt library did not load; the old one is gone"
      drainWork()

  unloadMods()
  storeClose()
  storeUnlock()
  result = (if gErrors > 0: 1 else: 0)

quit(main())
