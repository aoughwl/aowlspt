## tickfault -- what a host does with a mod whose `on_update` fails.
##
##     tickfault <dir containing the three fixture mods>
##
## `docs/DEBUGGING.md` described this mechanism for a long time before it
## existed: the host marks a faulting mod, stops dispatching to it, and says so
## in the log. What `tickMods` actually did was
##
##     discard cModApiOnUpdate(gMods[i].api, elapsed)
##
## -- three lines that threw the status away, so a mod that failed on every
## single frame of a raid did it in complete silence, with nothing anywhere
## naming it. This is the gate for the mechanism that closes that, and it is
## deliberately built around a mod that *does* fault, because a gate whose
## subject never faults is the failure species this project keeps producing: a
## check that passes because the thing it checks never happened.
##
## The host under it is a real one in the only sense that matters here. It is
## `host/common/modhost.nim` itself -- the same loader the backend, the client
## host and the simulator all use -- driven directly, with the `aowlspt_nim_*`
## surface stubbed down to the two entries the fixtures use (`log` and
## `now_ms`) and every other one refusing the way a host that cannot do a thing
## is supposed to. Three real mod DLLs are loaded through the real
## `describe`/`init`/`on_load` path and ticked through the real `tickMods`.
##
## The three fixtures, and why each one is here:
##
##   * `faultmod` fails on every tick. It is the subject.
##   * `goodmod` never fails, and is loaded **after** the faulting one, so that
##     a loop which gave up at the first failure would silence it.
##   * `flakymod` fails every fourth tick and never twice in a row. Over this
##     run it fails 150 times -- more than the threshold -- and must never be
##     disabled, which is what says the threshold counts a run rather than a
##     total.
##
## Every mod logs a line per tick through the host's own `log`, and the harness
## counts those. That is what makes "the host stopped dispatching to it" a
## measured fact rather than something inferred from a log line the host wrote
## about itself.
##
## Two checks are here for the *over*-correction rather than the omission, and
## they are the ones worth reading twice. A faulted mod must still be `live`
## and must still be enterable through `modEnter`, because the tempting
## implementation -- reuse the draining flag, it is already there and already
## interlocked -- would stop the mod answering HTTP and firing its hooks as
## well, and would leave `unloadOne`'s drain reading a flag somebody else set.
## The last check unloads the faulted mod and requires the drain to succeed.
##
## **Every check here has been made to fail on purpose.** Four mutations of
## `tickMods`, each one built and run:
##
##   * the honouring removed -- the original `discard cModApiOnUpdate(...)`
##     restored: **9 of the 22 checks go red**. The faulting mod is ticked all
##     601 times, it is not marked, its failure run is zero, and neither log
##     line exists. The thirteen that stay green are the right ones: they are
##     about the rest of the host being left alone, and the old code left it
##     alone by doing nothing at all. That split is the point -- the omission
##     was invisible precisely because nothing else broke.
##   * the threshold cut to 1, the hair trigger: **5 red**. `flakymod` is
##     disabled on its fourth tick, having failed exactly once.
##   * the reset on success removed, so the count is a total rather than a run:
##     **5 red**, and the same five. `flakymod` survives 480 ticks instead of 4
##     and is then disabled for having accumulated 120 failures across a
##     session it was working through.
##   * disabling done by setting the *draining* flag -- the tempting reuse,
##     since it exists and is already interlocked: **1 red**, and it is the
##     over-correction check. The mod stops being enterable, which in a real
##     host means its routes stop answering and its detours stop firing
##     because its tick failed. Nothing else notices, which is exactly why
##     that check has to be here.
##
## Build:
##
##   nimony c --passC:-I<repo>\abi -p:<repo>\host\common
##            -p:<repo>\installer\src -p:<repo>\aowl\src
##            -o:tickfault.exe tickfault.nim
import std/[strutils, syncio, cmdline]
import aowlsptinstall/winfs
import modhost

# The shim, again. Each binary that defines part of the `aowlspt_nim_*` surface
# has to see its declarations -- `modhost` includes it for its own emits, and a
# module that only imports `modhost` gets an implicit declaration of
# `aowl_out_copy` and a compile error. Both long-lived hosts and the simulator
# carry the same line for the same reason.
{.emit: """#include "aowlspt_shim.h" """.}

# ---------------------------------------------------------------------------
# The smallest host that can hold a mod
# ---------------------------------------------------------------------------
#
# `aowlspt_shim.h` builds its `AowlHostApi` vtable out of these symbols, so
# every one of them has to exist in the binary even where the answer is "this
# host cannot do that". The refusals are the same `ErrUnsupported` the real
# hosts give for the capabilities they lack -- see the simulator's `patch`.

const MaxSlots = 64

var gTickLines: array[MaxSlots, int]
  ## Per mod index: how many `TICK <n>` lines that mod has logged. Plain
  ## global storage rather than a `seq`, for the reason `modhost` gives for its
  ## own two arrays -- and because this is the count the whole gate turns on.

var gHostLines: seq[string] = @[]
  ## Everything the *loader* said, through `setLogSink`. The say-it-once checks
  ## read this.

var gAfterLoad = 0
  ## Where in `gHostLines` the ticking starts. The loader's own "loaded <name>
  ## (<guid>)" line names the guid, so counting lines about a mod from the
  ## beginning counts that one too and makes "it said two things" read as
  ## three. The say-it-once checks are about what ticking produced, so they
  ## start here.

proc noteHostLine(level, msg: string) =
  gHostLines.add level & "|" & msg
  # Echoed as well as recorded: a gate that fails should show what the host
  # said, not only that a count was wrong.
  write(stdout, "  host " & level & " " & msg & "\n")

proc hostLog(ctx: HostPtr; level: int32; msg: HostPtr; len: int32) {.
    exportc: "aowlspt_nim_log", cdecl.} =
  let text = readBytes(msg, len)
  let idx = int(cast[uint](ctx))
  if idx >= 0 and idx < MaxSlots and startsWith(text, "TICK "):
    gTickLines[idx] = gTickLines[idx] + 1

proc hostLastError(ctx: HostPtr; outPtr, outLen: HostPtr) {.
    exportc: "aowlspt_nim_last_error", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)

proc hostConfigGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_config_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  result = ErrNotFound

proc hostConfigSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                   val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_config_set", cdecl.} =
  result = ErrUnsupported

proc hostDbGet(ctx: HostPtr; path: HostPtr; pathLen: int32;
               outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_db_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  result = ErrUnsupported

proc hostDbPatch(ctx: HostPtr; path: HostPtr; pathLen: int32;
                 patch: HostPtr; patchLen: int32): int32 {.
    exportc: "aowlspt_nim_db_patch", cdecl.} =
  result = ErrUnsupported

proc hostRouteRegister(ctx: HostPtr; url: HostPtr; urlLen: int32; kind: int32;
                       cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_route_register", cdecl.} =
  result = ErrUnsupported

proc hostEventEmit(ctx: HostPtr; name: HostPtr; nameLen: int32;
                   payload: HostPtr; payloadLen: int32): int32 {.
    exportc: "aowlspt_nim_event_emit", cdecl.} =
  result = StatusOk

proc hostEventSubscribe(ctx: HostPtr; name: HostPtr; nameLen: int32;
                        cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_event_subscribe", cdecl.} =
  result = StatusOk

proc hostCall(ctx: HostPtr; target: HostPtr; targetLen: int32;
              args: HostPtr; argsLen: int32;
              outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_call", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  result = ErrUnsupported

proc hostResolve(ctx: HostPtr; typeName: HostPtr; nameLen: int32;
                 outHandle: HostPtr): int32 {.
    exportc: "aowlspt_nim_resolve", cdecl.} =
  result = ErrUnsupported

proc hostHandleRelease(ctx: HostPtr; handle: uint64) {.
    exportc: "aowlspt_nim_handle_release", cdecl.} =
  discard

proc hostPatch(ctx: HostPtr; target: HostPtr; targetLen: int32; kind: int32;
               cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch", cdecl.} =
  result = ErrUnsupported

proc hostNowMs(ctx: HostPtr): int64 {.exportc: "aowlspt_nim_now_ms", cdecl.} =
  result = elapsedMs()

proc hostInvokeMain(ctx: HostPtr; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_invoke_main", cdecl.} =
  result = ErrUnsupported

proc hostSchedule(ctx: HostPtr; delayMs: int32; cb, user: HostPtr): int32 {.
    exportc: "aowlspt_nim_schedule", cdecl.} =
  result = ErrUnsupported

proc hostStoreGet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_get", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  result = ErrNotFound

proc hostStoreSet(ctx: HostPtr; key: HostPtr; keyLen: int32;
                  val: HostPtr; valLen: int32): int32 {.
    exportc: "aowlspt_nim_store_set", cdecl.} =
  result = ErrUnsupported

proc hostStoreList(ctx: HostPtr; prefix: HostPtr; prefixLen: int32;
                   outPtr, outLen: HostPtr): int32 {.
    exportc: "aowlspt_nim_store_list", cdecl.} =
  discard cOutCopy(outPtr, outLen, cast[HostPtr](0), 0'i32)
  result = ErrUnsupported

proc patchFired(slot: int32; regs: HostPtr): int32 {.
    exportc: "aowlspt_nim_patch_fired", cdecl.} =
  ## Nothing can fire: `patch` is refused above. Zero means "run the original",
  ## which is the only safe answer for a slot that cannot exist.
  result = 0'i32

proc teardown(index: int) =
  ## What a mod registered, dropped before its library is freed. This host
  ## takes no registrations -- every entry that could produce one refuses -- so
  ## there is nothing to drop. It exists because `unloadOne` refuses without
  ## one, and the last check unloads a mod.
  discard

# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

var fails = 0

proc check(what: string; cond: bool) =
  if cond:
    write(stdout, "  ok    " & what & "\n")
  else:
    write(stdout, "  FAIL  " & what & "\n")
    inc fails

proc checkEq(what: string; got, want: int) =
  if got == want:
    write(stdout, "  ok    " & what & " (" & $got & ")\n")
  else:
    write(stdout, "  FAIL  " & what & ": got " & $got & ", wanted " &
                  $want & "\n")
    inc fails

proc hostLinesAbout(needle: string): int =
  ## Lines the loader wrote **after** loading finished. See `gAfterLoad`.
  result = 0
  for i in gAfterLoad ..< gHostLines.len:
    if contains(gHostLines[i], needle):
      inc result

proc hostLinesAboutAt(level, needle: string): int =
  result = 0
  for i in gAfterLoad ..< gHostLines.len:
    if startsWith(gHostLines[i], level & "|") and contains(gHostLines[i], needle):
      inc result

const
  FaultGuid = "aowl.test.faultmod"
  GoodGuid = "aowl.test.goodmod"
  FlakyGuid = "aowl.test.flakymod"

  Ticks = 601
    ## Enough that `flakymod` fails 150 times -- comfortably past
    ## `TickFaultLimit` -- and odd in the right way that its final tick is a
    ## successful one, so its run of consecutive failures is zero at the end
    ## rather than one. A count that only holds for an even number of ticks
    ## would be a check about the arithmetic of the fixture rather than about
    ## the host.

proc modDll(root, name: string): string =
  ## `aowl build-mod` puts a mod's library at `<mod>/bin/<mod>.dll`.
  result = joinPath(joinPath(joinPath(root, name), "bin"), name & ".dll")

proc main(): int =
  if paramCount() < 1:
    write(stderr, "tickfault: give me the directory holding the fixture mods\n")
    return 2
  let root = paramStr(1)

  startClock()
  setLogSink(noteHostLine)
  setModTeardown(teardown)

  write(stdout, "tickfault: three mods, one of which fails every tick\n")

  # Load order is part of the test: the faulting mod goes in first, so a loop
  # that stopped at a failure would take the other two with it.
  for name in ["faultmod", "goodmod", "flakymod"]:
    let dll = modDll(root, name)
    if not fileExists(dll):
      write(stderr, "tickfault: no library at " & dll &
                    " -- build the fixtures first\n")
      return 2
    if not loadMod(dll, SideSim, "aowlspt-tickfault", "1.0.0"):
      write(stderr, "tickfault: " & dll & " did not load\n")
      return 2

  gAfterLoad = gHostLines.len

  let fault = modIndexOf(FaultGuid)
  let good = modIndexOf(GoodGuid)
  let flaky = modIndexOf(FlakyGuid)
  check("all three fixtures loaded", fault >= 0 and good >= 0 and flaky >= 0)
  if fault < 0 or good < 0 or flaky < 0:
    return 1
  check("the faulting mod is ticked before the bystander", fault < good)

  for k in 0 ..< Ticks:
    tickMods(16'i64)

  write(stdout, "after " & $Ticks & " ticks:\n")

  # 1. The host stopped dispatching to it, and stopped at the threshold.
  checkEq("the faulting mod ran exactly TickFaultLimit ticks and no more",
          gTickLines[fault], TickFaultLimit)
  check("the faulting mod is marked faulted", modTickFaulted(fault))
  checkEq("its failure run is the threshold", modTickFailures(fault),
          TickFaultLimit)

  # 2. It said so, once each way.
  checkEq("one warn line names the faulting mod on its first failure",
          hostLinesAboutAt("warn ", FaultGuid), 1)
  checkEq("one error line says it is disabled",
          hostLinesAboutAt("error", FaultGuid), 1)
  check("the disabling line is the one docs/DEBUGGING.md tells a player to " &
        "search for",
        hostLinesAbout("faulted, mod disabled") == 1)
  check("the first line names the status by its ABI name",
        hostLinesAbout("AOWLSPT_ERR_MOD_FAULT") >= 1)
  checkEq("and nothing else was said about it, over 601 frames",
          hostLinesAbout(FaultGuid), 2)

  # 3. The rest of the host is untouched.
  checkEq("the bystander was ticked every single time", gTickLines[good], Ticks)
  checkEq("nothing was said about the bystander", hostLinesAbout(GoodGuid), 0)

  # 4. A threshold, not a hair trigger.
  checkEq("the flaky mod was ticked every single time", gTickLines[flaky],
          Ticks)
  check("the flaky mod is not disabled, having failed " & $(Ticks div 4) &
        " times without ever failing twice in a row",
        not modTickFaulted(flaky))
  checkEq("its failure run is back to zero", modTickFailures(flaky), 0)
  # And the flood check, which is the one a flaky mod is uniquely able to make.
  # It fails 150 times, each of them the first failure of a fresh run, so a
  # host that says something on the first failure of a *run* writes 150 lines
  # here rather than one. That is a log line every fourth frame -- the same
  # denial of service as one per frame, wearing a disguise -- and it is what
  # this fixture caught in the first version of the mechanism.
  checkEq("the flaky mod is named once, not once per run of failures",
          hostLinesAboutAt("warn ", FlakyGuid), 1)
  checkEq("and never at error, because it was never disabled",
          hostLinesAboutAt("error", FlakyGuid), 0)

  # 5. Disabled is not drained. This is the check that separates the right
  #    implementation from the tempting one: reusing the interlocked draining
  #    flag would also stop the mod's routes, events and hooks, and would leave
  #    `unloadOne` reading a flag it did not set.
  check("the faulted mod is still loaded", modIsLive(fault))
  var entered = false
  if modGuardable(fault):
    entered = modEnter(fault)
    if entered:
      check("a call into the faulted mod still gets a reference",
            modInflight(fault) == 1'i64)
      modLeave(fault)
  check("the faulted mod is still enterable -- only its tick stopped", entered)
  checkEq("and nobody is left inside it", int(modInflight(fault)), 0)

  # 6. And it can still be taken out the ordinary way: the drain finds nobody
  #    inside and succeeds, which it could not if the flag had been co-opted.
  var err = ""
  let unloaded = unloadOne(fault, err)
  check("the faulted mod still unloads cleanly" &
        (if err.len > 0: ": " & err else: ""), unloaded)

  # 7. The host keeps going afterwards.
  let before = gTickLines[good]
  for k in 0 ..< 10:
    tickMods(16'i64)
  checkEq("the bystander keeps ticking after the faulted mod is unloaded",
          gTickLines[good] - before, 10)

  if fails == 0:
    write(stdout, "tickfault: every check passed\n")
    return 0
  write(stdout, "tickfault: " & $fails & " check(s) failed\n")
  return 1

quit(main())
