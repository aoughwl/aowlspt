# errdlg.nim -- CATCH THE IN-GAME ERROR DIALOG. `include`d into `aowlhost.nim`
# (NOT a separate module) so it shares that file's guarded raw primitives,
# `cRegsInt`, logging (`okLog`/`info`/`warn`), `hexOf`, `attachDrain`, the
# VEH/SEH guard and the host-thread id -- the same discipline botcap and botdiag
# use.
#
# ## The gap this closes
#
# We had two watchers and neither could see this. `harness.py` tails the host log
# and distinguishes DIED (process gone) from IDLE (log went quiet); `crashwatch.py`
# tails the client's own logs for exception text. An in-game error dialog defeats
# both: the process is alive, the host log keeps ticking, and the client often
# logs nothing at Error level at all -- it just puts a modal window on screen and
# waits forever for a click. That is identical, from outside, to the game sitting
# at profile-select waiting for a human, which is the NORMAL end state of every
# scripted launch. So an unattended `autoraid` run reads "still going" for the
# whole timeout. Measured: a raid-load break put up an error dialog and the
# session sat stuck ~12 minutes before anyone noticed.
#
# A dialog is a crash with a button on it. This makes it announce itself in the
# same second the client decides to show one, with the text it is showing.
#
# ## What it does
#
# Three READ-ONLY POSTFIX detours on the `EFT.UI.PreloaderUI` entry points every
# error window in this client is raised through (all three RVAs offline-verified
# UNIQUE -- see `abi/aowlspt_errdlg.h` for the resolution and the prologue
# bytes). Each one reads the header and message out of the argument registers,
# writes ONE line to the host log, and returns 0 so the original always runs.
#
# **Nothing is suppressed.** The window still appears exactly as it would have,
# because hiding the error from the person at the keyboard in order to reveal it
# to the tooling is a strictly worse trade. This is an observer, not a patch.
#
# ## The contract the outside world depends on
#
# Exactly one line per dialog, and it always starts with the marker `ERRORDIALOG`:
#
#     ERRORDIALOG kind=<message|exception|critical> header="..." text="..."
#
# `tools/crashwatch.py` and `tools/harness.py` treat that marker as a crash-class
# event. Keep it on one line and keep the marker literal -- non-printing
# characters and newlines inside a .NET message are collapsed to '?' by
# `aowl_ed_str_at` for exactly that reason.
#
# A field we could not read is reported as `<unreadable>`, never as `""`. An
# empty string reads as "the dialog had no message", which is a different and
# usually false claim -- and a confidently wrong diagnostic is worse than none.

# ---- offsets, targets and guarded readers from abi/aowlspt_errdlg.h ----
proc cEdTargetAt(i: int32): Il2CppPtr {.importc: "aowl_ed_target_at", nodecl.}
proc cEdTargetName(i: int32): Il2CppPtr {.importc: "aowl_ed_target_name", nodecl.}
proc cEdTargetCount(): int32 {.importc: "aowl_ed_target_count", nodecl.}
proc cEdVerified(): int32 {.importc: "aowl_ed_verified_count", nodecl.}
proc cEdRejected(): int32 {.importc: "aowl_ed_rejected_count", nodecl.}
proc cEdPrimeAll(): int32 {.importc: "aowl_ed_prime_all", nodecl.}
proc cEdStrAt(s: Il2CppPtr; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_ed_str_at", nodecl.}
proc cEdStrField(obj: Il2CppPtr; off: int32; outBuf: cstring; cap: int32): int32 {.
  importc: "aowl_ed_str_field", nodecl.}
proc cEdOffExcMessage(): int32 {.importc: "aowl_ed_off_exc_message", nodecl.}
proc cEdOffExcClassName(): int32 {.importc: "aowl_ed_off_exc_classname", nodecl.}
proc cEdOffExcStack(): int32 {.importc: "aowl_ed_off_exc_stack", nodecl.}
proc cEdTargetShape(i: int32): int32 {.importc: "aowl_ed_target_shape", nodecl.}
proc cEdTargetKind(i: int32): Il2CppPtr {.importc: "aowl_ed_target_kind", nodecl.}
proc cEdTargetSeverity(i: int32): int32 {.importc: "aowl_ed_target_severity", nodecl.}

const
  EdShapeString = 0'i32
    ## R8 is a System.String -- read it directly.
  EdShapeException = 1'i32
    ## R8 is a System.Exception -- the text lives in fields, not the register.
  EdSevCritical = 1'i32

# The slot globals (gErrDlgMsgSlot / gErrDlgExcSlot / gErrDlgCritSlot) and the
# flag `gErrDlg` are declared in aowlhost.nim beside the other detour slots.

const
  ErrDlgBufCap = 512'i32
    ## Plenty for a header and for the first screenful of a .NET message. A
    ## truncated message is marked as truncated rather than silently cut.
  ErrDlgKindBase = 23'i32
    ## The detour `kind` of target row 0; rows 1 and 2 take the next two. Kinds
    ## 20/21/22 belong to the true-deploy signals and the pact owner on this
    ## branch -- this feature was originally written against a base where they
    ## were free, and the collision surfaced only at merge time. That it
    ## surfaced at all is the `KindMaxFeature` range test doing its job: the two
    ## hand-maintained `kind == 2 or kind == 3 or ...` chains it replaced would
    ## have merged clean and silently mis-signalled the drain.
  ErrDlgMaxLogged = 8
    ## After this many dialogs in one session, stop writing full lines and just
    ## count. A client that raises an error window in a loop must not be able to
    ## turn the host log into a token bomb (CLAUDE.md section 8).

# Fixed buffers: a detour body must not allocate. These are only ever touched
# from the detour body, which runs one-at-a-time on the Unity main thread.
var gErrDlgHdrBuf: array[512, char]
var gErrDlgTxtBuf: array[512, char]

proc edBufStr(buf: var array[512, char]; n: int32): string =
  ## Turn a filled C buffer into a Nim string. `n <= 0` means the guarded reader
  ## refused the slot -- which is NOT the same as an empty string, so it is
  ## reported as unreadable rather than as "".
  if n <= 0:
    return "<unreadable>"
  result = newString(int(n))
  for i in 0 ..< int(n):
    result[i] = buf[i]

proc edKindName(row: int): string =
  ## The reported `kind=`, read from the ROW, never reconstructed from an index.
  if row < 0 or row >= int(cEdTargetCount()):
    return "unknown"
  readCString(cEdTargetKind(int32(row)))

proc errDlgBodyImpl(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_errdlg_body", cdecl.} =
  ## The whole read-and-log body, run under the VEH/SEH guard. `a` is the detour
  ## `regs`. Reads only; writes nothing to the game. Returns a non-nil sentinel
  ## on clean completion; the C guard returns nil if it faulted.
  ##
  ## Which target fired is taken from `gErrDlgFiring`, set by the dispatcher
  ## immediately before the call -- the regs block carries no target identity.
  let regs = a
  let row = gErrDlgFiring          # the TABLE ROW, not a derived index
  let kind = edKindName(row)
  let shape = cEdTargetShape(int32(row))
  # NOTE: gErrDlgCount is incremented by the CALLER, before the guard is armed,
  # so a dialog is counted exactly once whether or not reading its text faults.
  # Counting it here would miss the faulting case; counting it in both places
  # would double it.

  if gErrDlgCount > ErrDlgMaxLogged:
    # Count silently past the cap, but say so exactly once at the boundary so
    # the log states that it stopped rather than appearing to have missed them.
    if gErrDlgCount == ErrDlgMaxLogged + 1:
      warn "ERRORDIALOG kind=" & kind & " header=\"<suppressed>\" " &
           "text=\"this client has raised " & $ErrDlgMaxLogged & " error " &
           "dialogs; further ones are COUNTED but not printed, so a client " &
           "erroring in a loop cannot flood the host log. The count is in the " &
           "boot table and in `state`.\""
    return cast[Il2CppPtr](1)

  # RDX = header on all three overloads.
  let hdrPtr = cast[Il2CppPtr](cRegsInt(regs, 1'i32))
  let hn = cEdStrAt(hdrPtr, cast[cstring](addr gErrDlgHdrBuf[0]), ErrDlgBufCap)
  let header = edBufStr(gErrDlgHdrBuf, hn)

  var text: string
  var extra = ""
  if shape == EdShapeException:
    # R8 = System.Exception. The message lives in a field, not a register.
    let excPtr = cast[Il2CppPtr](cRegsInt(regs, 2'i32))
    let mn = cEdStrField(excPtr, cEdOffExcMessage(),
                         cast[cstring](addr gErrDlgTxtBuf[0]), ErrDlgBufCap)
    text = edBufStr(gErrDlgTxtBuf, mn)
    # _className is filled lazily by this runtime and is usually NULL, so it is
    # reported only when it is actually there. An invented type name in a crash
    # report is worse than no type name.
    let cn = cEdStrField(excPtr, cEdOffExcClassName(),
                         cast[cstring](addr gErrDlgHdrBuf[0]), ErrDlgBufCap)
    if cn > 0:
      extra = " type=\"" & edBufStr(gErrDlgHdrBuf, cn) & "\""
    let sn = cEdStrField(excPtr, cEdOffExcStack(),
                         cast[cstring](addr gErrDlgHdrBuf[0]), ErrDlgBufCap)
    if sn > 0:
      extra = extra & " stack=\"" & edBufStr(gErrDlgHdrBuf, sn) & "\""
    extra = extra & " exc=0x" & hexOf(cast[uint64](excPtr))
  else:
    # R8 = message, a plain System.String, on both the (string,string,Action)
    # overload and ShowCriticalErrorScreen.
    let msgPtr = cast[Il2CppPtr](cRegsInt(regs, 2'i32))
    let tn = cEdStrAt(msgPtr, cast[cstring](addr gErrDlgTxtBuf[0]), ErrDlgBufCap)
    text = edBufStr(gErrDlgTxtBuf, tn)

  # Remember the first one for `state` and for the boot table. The FIRST is kept
  # rather than the latest, because a cascade's first error is the cause and the
  # rest are usually consequences of it.
  if gErrDlgFirst.len == 0:
    gErrDlgFirst = kind & ": " & header & " -- " & text
  if cEdTargetSeverity(int32(row)) == EdSevCritical:
    gErrDlgCritical = true

  warn "ERRORDIALOG kind=" & kind & " header=\"" & header &
       "\" text=\"" & text & "\"" & extra
  return cast[Il2CppPtr](1)

# The VEH/SEH guard thunk -- `aowl_p_p_seh` (abi/aowlspt_shim.h) arms a vectored
# exception handler + setjmp, calls the body, and returns nil instead of letting
# an access violation propagate. This body only READS, but it reads pointers
# handed to it by a register, and a register we misread is exactly the case the
# guard exists for. NEVER nest this: one `aowl_p_p_seh` per body (CLAUDE.md 5).
{.emit: """
extern void* aowl_errdlg_body(void* a);
static void* aowl_errdlg_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_errdlg_body, a);
}
""".}
proc cErrDlgBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_errdlg_body_guarded", nodecl.}

proc errDlgFired(regs: Il2CppPtr; row: int) =
  ## Fired from the postfix detour on whichever PreloaderUI entry point raised
  ## the window, on the Unity main thread. `row` is the index into the target
  ## table that this slot bound, recorded at bind time; the body reads the shape
  ## and the kind out of that row rather than deriving either from arithmetic.
  ## Runs the whole read under the guard: a fault here is logged and swallowed,
  ## because the error window itself must still come up for the person at the
  ## keyboard.
  gErrDlgFiring = row
  inc gErrDlgCount        # counted once, here, whether or not the read faults
  if cErrDlgBodyGuarded(regs) == nil:
    warn "ERRORDIALOG kind=" & edKindName(row) & " header=\"<unreadable>\" " &
         "text=\"the client raised an error dialog and the guarded read of its " &
         "header/message FAULTED (caught; the game survived). The dialog is " &
         "real and is on screen -- only its text could not be recovered.\""
    if gErrDlgFirst.len == 0:
      gErrDlgFirst = edKindName(row) & ": <text unreadable>"

proc bindErrDlg(verbose: bool): bool =
  ## Installs the three READ-ONLY POSTFIX detours from the verified static
  ## targets in `aowlspt_errdlg.h`. Flag-gated on `catchErrorDialogs`.
  ##
  ## Binding is BEST-EFFORT PER TARGET and the result says exactly which of the
  ## three took: catching two kinds of dialog out of three is strictly better
  ## than catching none, and a partial bind that pretended to be a full one
  ## would be a check that cannot fail (CLAUDE.md 9b). It returns true if AT
  ## LEAST ONE bound, and the log names the ones that did not.
  if not gErrDlg:
    return false
  if gErrDlgMsgSlot >= 0 or gErrDlgExcSlot >= 0 or gErrDlgCritSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false

  # Prime the prologue snapshot for all three before anything is patched. The
  # lazy path in aowl_pro_verify would also be correct; this just makes the
  # boot-time count honest.
  discard cEdPrimeAll()

  var bound = 0
  var missed = ""
  let count = cEdTargetCount()
  if int(count) > gErrDlgRow.len:
    # A row was added to `aowl_ed_targets` without adding a slot global and a
    # `kind` branch in attachDrain for it. Refuse the whole feature rather than
    # binding the first three and quietly dropping the rest: a watcher that
    # covers some entry points while reporting itself as armed is the exact
    # cannot-fail shape CLAUDE.md 9b is about.
    warn "errdlg: aowl_ed_targets has " & $int(count) & " rows but this host " &
         "only has " & $gErrDlgRow.len & " slots (kinds 20.." &
         $(20 + gErrDlgRow.len - 1) & ") wired for them. REFUSING to bind any " &
         "of them rather than silently covering only the first " &
         $gErrDlgRow.len & ". Add a slot global, a `kind` branch in " &
         "attachDrain, a dispatch line in patchFired, and bump KindMaxFeature."
    return false
  for i in 0 ..< int(count):
    let spec = readCString(cEdTargetName(int32(i)))
    let fn = cEdTargetAt(int32(i))
    if fn == nil:
      missed = missed & (if missed.len > 0: ", " else: "") & spec
      if verbose:
        info "errdlg target " & $i & " (" & spec &
             ") did not verify against the startup prologue snapshot on this " &
             "build; that KIND of error dialog will not be caught"
      continue
    # Row i claims detour kind ErrDlgKindBase+i, which routes the slot global inside
    # attachDrain. That arithmetic decides only WHICH SLOT a row lands in, which
    # is harmless -- any row can have any slot. What must NOT be inferred from it
    # is how to READ the row's arguments, so the row index is recorded here and
    # the dispatcher reads the shape and kind back out of the row itself.
    if attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                   int32(ErrDlgKindBase + i)):
      if i < gErrDlgRow.len:
        gErrDlgRow[i] = i
      inc bound
    else:
      missed = missed & (if missed.len > 0: ", " else: "") & spec

  if bound == 0:
    warn "catchErrorDialogs is on but NONE of the " & $int(count) &
         " PreloaderUI error-screen entry points bound (" & $int(cEdVerified()) &
         " verified, " & $int(cEdRejected()) & " REJECTED by the prologue " &
         "snapshot). In-game error dialogs will NOT be caught on this run, so " &
         "an unattended run that hits one will look IDLE rather than failed. " &
         "Missed: " & missed
    return false

  if bound < int(count):
    warn "errdlg armed on " & $bound & " of " & $int(count) &
         " error-screen entry points; NOT caught: " & missed &
         ". A dialog raised through a missed entry point will still look like " &
         "an idle client, so treat an IDLE verdict on this run as inconclusive."
  else:
    okLog "errdlg ARMED: read-only postfix detours on all " & $int(count) &
          " PreloaderUI error-screen entry points. An in-game error dialog now " &
          "writes one ERRORDIALOG line to this log the moment it is raised; " &
          "the dialog itself is never suppressed."
  return true
