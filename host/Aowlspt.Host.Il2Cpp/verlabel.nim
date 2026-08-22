# verlabel.nim -- the main menu's CORNER VERSION LABEL, host/mod-driven.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares that file's guarded
# raw primitives (`cIsReadable`, `cReadPtrAt`, `cReadI32At`, `cWordAt`,
# `rawReadVersionString`, `looksLikeVersion`), its VirtualQuery-checked
# reference-field write (`cUxWritePtr`), its logging (`okLog`/`warn`/`info`),
# `hexOf`, `cRegsInt`, `cThreadId`, `attachDrain`, `newString`/`gRt`, and the
# VEH/SEH guard.
#
# WHAT IT DOES
# ------------
# A stock post-1.0 corner label reads `1.1.0.1.4677 | PvE`. With `uxVersionLabel`
# on it reads
#
#     aowlspt | aoughwl.com | 1.1.0.1.4677
#
# and the version in it is the CLIENT'S OWN, read at runtime. No version number
# appears in this host, so a client update fixes the label by itself.
#
# HOW, IN ONE PARAGRAPH
# ---------------------
# `EFT.UI.PreloaderUI::RefreshCornerLabel` @ 0x156d050 COMPOSES that label out of
# four `PreloaderUI` string fields, seeded from `_alphaVersionText` (+0x110) and
# appending `_sessionIdText` (+0x118), `_sessionModeText` (+0x128) and
# `_commitsNotMatchText` (+0x120), each behind an "is it null or empty?" test,
# then stores the result into the `LocalizedText` at +0x20 and TAIL-CALLS the
# repaint. The full disassembly, and the `test rcx,rcx / cmp [rcx+0x10],0` pair
# that proves an empty component is skipped separator and all, is in
# `abi/aowlspt_verlabel.h`.
#
# So this feature does not write text anywhere the UI can see. It PREFIXES that
# composer, arranges its inputs -- our composed string into +0x110, nulls into
# the components we do not want -- and returns 0 so the game's own code runs and
# repaints for us. That is why it cannot repeat the Phase-2a bug (a `m_text`
# store that lands and never repaints): nothing here writes `m_text`, pokes a
# dirty byte, or calls the stripped `ForceMeshUpdate` stub.
#
# WHY NOT `PreloaderUI::Update`
# -----------------------------
# Because three features already want it (the F3 overlay, the ESP probe, the
# menu mode text) and two detours on one function have the second overwrite the
# first's trampoline. `RefreshCornerLabel` is hooked by nothing else in this
# host, is not per-frame, and -- being the label's ONLY writer -- catches every
# late recomposition that a one-shot `Awake` write would have been silently
# undone by.
#
# SAFETY
# ------
#   * flag-gated `uxVersionLabel`, default OFF;
#   * the detour target is 16-byte prologue-verified against committed
#     executable memory before anything binds (`aowl_vlb_fn`), so on any other
#     build this is a silent no-op;
#   * the whole body runs under ONE `aowl_p_p_seh` guard -- one, never nested,
#     because the guard is not re-entrant and a nested one disarms the outer on
#     return; the managed string allocation deliberately shares that one guard;
#   * every pointer hop is `cIsReadable`-guarded, every store goes through the
#     VirtualQuery-checked `cUxWritePtr`, and a refused store leaves the game's
#     own value exactly where it was;
#   * printable-ASCII and length validated at both ends of the wire;
#   * self-disables after `VerLabelMaxFaults` guarded bodies fail;
#   * NO REPEATED ALLOCATION. A managed string is allocated only when the
#     composed text differs from what is already in the field, so the steady
#     state is zero allocations however often the game recomposes.

# ---- the verified target and offsets (abi/aowlspt_verlabel.h) ----
proc cVlbFn(i: int32): Il2CppPtr {.importc: "aowl_vlb_fn", nodecl.}
proc cVlbName(i: int32): Il2CppPtr {.importc: "aowl_vlb_name", nodecl.}
proc cVlbRva(i: int32): uint32 {.importc: "aowl_vlb_rva", nodecl.}
proc cVlbOkCount(): int32 {.importc: "aowl_vlb_ok_count", nodecl.}
proc cVlbBadCount(): int32 {.importc: "aowl_vlb_bad_count", nodecl.}
proc cVlbOffVersionText(): int32 {.
  importc: "aowl_vlb_off_version_text", nodecl.}
proc cVlbOffSessionId(): int32 {.importc: "aowl_vlb_off_session_id", nodecl.}
proc cVlbOffCommits(): int32 {.importc: "aowl_vlb_off_commits", nodecl.}
proc cVlbOffSessionMode(): int32 {.
  importc: "aowl_vlb_off_session_mode", nodecl.}
proc cVlbOffCornerLabel(): int32 {.
  importc: "aowl_vlb_off_corner_label", nodecl.}
proc cVlbOffLocalizedText(): int32 {.
  importc: "aowl_vlb_off_localized_text", nodecl.}

const
  VlbTRefresh = 0'i32
  VerLabelMaxFaults = 3
    ## After this many guarded bodies have faulted the feature switches itself
    ## off for the session. Three, not one: a single fault during a scene change
    ## is worth surviving, a pattern of them is not worth continuing through.
  VerLabelVersionToken* = "{version}"
    ## The one substitution a format string gets: replaced with the client's own
    ## version, read live out of `_alphaVersionText`. A format containing no
    ## token is still legal -- it simply produces a label with no version in it,
    ## which is a thing somebody may genuinely want.
  VerLabelDefaultFormat* = "aowlspt | aoughwl.com | " & VerLabelVersionToken
    ## What the corner label reads when nobody has said otherwise. This is the
    ## ONLY place the default lives; the mod-facing API, the manager and the
    ## backend all just carry overrides of it.
  VerLabelMax* = 63
    ## The longest composed label this will write. Deliberately <= 64, which is
    ## the cap in `rawReadVersionString`: the read-back that decides "has this
    ## already been applied?" uses that reader, so a label longer than its cap
    ## would read back as "" and be rewritten -- and therefore REALLOCATED --
    ## on every single composition. Keeping the two limits in agreement is what
    ## makes the steady state genuinely zero-allocation.

## `gVerLabelSlot` (the kind=14 PREFIX detour slot) and `gVerLabelOn` (the
## `uxVersionLabel` flag) are declared in `aowlhost.nim` next to `gDebugUiSlot`,
## and have to be: `attachDrain` and `patchFired` are both defined ABOVE this
## file's include point and both name the slot. Procs resolve across the whole
## module regardless of order; module-level `var`s do not. The rest of the state
## is local to this feature and lives here.
var gVerLabelFaults = 0
var gVerLabelOff = false           ## self-disabled after too many faults
var gVerLabelFormat = VerLabelDefaultFormat
var gVerLabelVersion = ""          ## the client's own version, captured live
var gVerLabelApplied = ""          ## what this host last wrote into +0x110
var gVerLabelFires = 0
var gVerLabelWrites = 0
var gVerLabelLogged = false        ## the one-shot identification log

proc verLabelAcceptableFormat(s: string): bool =
  ## Whether `s` is a format this host will carry: non-empty, printable ASCII,
  ## and short enough that even a long version substituted into it still fits
  ## `VerLabelMax`. Checked here as well as at the manager and in the mod API,
  ## because a value that cannot survive the trip should be refused wherever it
  ## can still be reported.
  if s.len == 0 or s.len > VerLabelMax:
    return false
  for ch in s:
    if ord(ch) < 0x20 or ord(ch) > 0x7E:
      return false
  result = true

proc verLabelSetFormat(s: string) =
  ## Called from the host's own tick loop (NOT the Unity thread) when the
  ## backend poll produced a new format. It only records the wish; the Unity
  ## thread is the only thing that ever touches managed memory.
  ##
  ## An empty string means "the backend has nothing to say" and RESTORES THE
  ## DEFAULT rather than blanking the label. A manager that is down, an older
  ## manager that omits the field, and a mod that cleared its override must all
  ## end up at `VerLabelDefaultFormat`, which is the string the user asked for.
  if not gVerLabelOn or gVerLabelOff:
    return
  let want = (if s.len == 0: VerLabelDefaultFormat else: s)
  if want == gVerLabelFormat or not verLabelAcceptableFormat(want):
    return
  gVerLabelFormat = want
  info "version label: the backend wants the corner label formatted as \"" &
       want & "\"; it will be applied on the next corner-label refresh"

proc verLabelCompose(): string =
  ## The format with `{version}` replaced by the client's own version string.
  ## Returns "" when the result would not be a label worth writing -- which is
  ## the same answer as "leave the stock label alone".
  if gVerLabelVersion.len == 0:
    return ""
  var out1 = ""
  var i = 0
  while i < gVerLabelFormat.len:
    if i + VerLabelVersionToken.len <= gVerLabelFormat.len and
       gVerLabelFormat[i ..< i + VerLabelVersionToken.len] ==
         VerLabelVersionToken:
      out1.add gVerLabelVersion
      i = i + VerLabelVersionToken.len
    else:
      out1.add gVerLabelFormat[i]
      inc i
  if out1.len == 0 or out1.len > VerLabelMax:
    return ""
  for ch in out1:
    if ord(ch) < 0x20 or ord(ch) > 0x7E:
      return ""
  result = out1

## Carries the string for the guarded allocation, for the same reason
## `gBrandText` does: `aowl_p_p_seh` passes exactly one pointer.
var gVerLabelAlloc = ""

proc verLabelNewString(a: Il2CppPtr): Il2CppPtr =
  ## Allocates the managed `System.String` for `gVerLabelAlloc`.
  ##
  ## NOT separately SEH-guarded, and that is deliberate: it is only ever called
  ## from `verLabelBody`, which already runs under one `aowl_p_p_seh`, and that
  ## guard is NOT re-entrant -- a nested one shares the single thread-local
  ## `jmp_buf`, disarms the outer guard when it returns, and leaves the rest of
  ## the body running unprotected. `debugui.nim`'s `duNewStringImpl` and
  ## `modetext.nim`'s `modeTextNewString` carry the same comment for the same
  ## reason. A fault in `il2cpp_string_new` is therefore caught by the OUTER
  ## guard, which is the correct place for it. `a` is unused.
  result = newString(gRt, gVerLabelAlloc)

{.emit: """
extern void* aowl_vlb_body(void* a);
static void* aowl_vlb_body_guarded(void* a) {
    return aowl_p_p_seh((void*)aowl_vlb_body, a);
}
""".}
proc cVlbBodyGuarded(a: Il2CppPtr): Il2CppPtr {.
  importc: "aowl_vlb_body_guarded", nodecl.}

proc verLabelClear(self: Il2CppPtr; off: int32; what: string) =
  ## Null one of the components the composer would otherwise append.
  ##
  ## A NULL store is the safest write there is on a managed heap -- it can never
  ## create the old-to-young reference a write barrier exists to record -- and
  ## the composer's own `test rcx,rcx / je` in front of every append is what
  ## makes it mean "skip this segment, separator and all" rather than "append
  ## nothing and leave a dangling ` | `". Already-null is left alone so a
  ## refusal below can only ever be about a slot that really needed writing.
  if cIsReadable(self, off + 8'i32) == 0'i32:
    return
  if cReadPtrAt(self, off) == nil:
    return
  if cUxWritePtr(self, off, cast[Il2CppPtr](0)) == 0'i32:
    warn "version label: " & what & " (+0x" & hexOf(uint64(off)) &
         ") was not safely writable; it is left as the game set it and the " &
         "corner label will still show it"

proc verLabelBody(a: Il2CppPtr): Il2CppPtr {.
    exportc: "aowl_vlb_body", cdecl.} =
  ## The whole managed-touching body, under ONE guard. `a` is the live
  ## `PreloaderUI` this, already non-nil and readable when we get here, and we
  ## are running BEFORE the original `RefreshCornerLabel` composes.
  ##
  ## Returns a non-nil sentinel on clean completion; the guard returns nil if
  ## this faulted, and the caller counts that toward the self-disable.
  result = cast[Il2CppPtr](1)
  let self = a
  let verOff = cVlbOffVersionText()

  # ---- capture the CLIENT'S OWN version, once ----
  #
  # `PreloaderUI::Awake` seeds +0x110 from `LocalizedText.FormattedText` (+0xA0)
  # -- see the header -- so by the time any composition happens the real version
  # is already sitting in that field. We read it there by the fixed String
  # layout, and only accept it if it LOOKS like a version, which is
  # self-validating: a slot whose bytes are not a short version-ish ASCII string
  # is refused rather than guessed at. If it is missing we try the label's own
  # `FormattedText` before giving up.
  var cur = ""
  if cIsReadable(self, verOff + 8'i32) != 0'i32:
    cur = rawReadVersionString(cReadPtrAt(self, verOff))
  if gVerLabelVersion.len == 0 and looksLikeVersion(cur):
    gVerLabelVersion = cur
  if gVerLabelVersion.len == 0:
    let lblOff = cVlbOffCornerLabel()
    if cIsReadable(self, lblOff + 8'i32) != 0'i32:
      let lbl = cReadPtrAt(self, lblOff)
      if lbl != nil and cIsReadable(lbl, cVlbOffLocalizedText() + 8'i32) != 0'i32:
        let s = rawReadVersionString(cReadPtrAt(lbl, cVlbOffLocalizedText()))
        if looksLikeVersion(s):
          gVerLabelVersion = s

  # ---- the one-shot identification log ----
  #
  # This is what makes the target verifiable from a real run rather than from
  # this file's claims: the object the user is looking at, the label it owns,
  # and the version string read out of the game BEFORE anything is written.
  if not gVerLabelLogged:
    gVerLabelLogged = true
    var lbl: Il2CppPtr = nil
    if cIsReadable(self, cVlbOffCornerLabel() + 8'i32) != 0'i32:
      lbl = cReadPtrAt(self, cVlbOffCornerLabel())
    okLog "version label: FOUND the corner label composer. parent chain = " &
          "EFT.UI.PreloaderUI(this=0x" & hexOf(cast[uint64](self)) &
          ") -> _alphaVersionLabel:LocalizedText(+0x" &
          hexOf(uint64(cVlbOffCornerLabel())) & ")=0x" &
          hexOf(cast[uint64](lbl)) &
          " ; _alphaVersionText(+0x" & hexOf(uint64(verOff)) &
          ") currently reads \"" & cur & "\" and the client's version was " &
          "read from the game as \"" & gVerLabelVersion & "\" (never " &
          "hardcoded). The composed label will be \"" & verLabelCompose() & "\""

  if gVerLabelVersion.len == 0:
    # Nothing trustworthy to substitute. Leave the stock label exactly alone --
    # that is always a safe answer, and a wrong version would not be.
    return

  let want = verLabelCompose()
  if want.len == 0:
    return

  # ---- the seed: our composed string into _alphaVersionText ----
  #
  # THE ONLY ALLOCATION, and only when the field does not already hold what we
  # want. In the steady state -- which is every composition after the first --
  # `cur == want` and this whole block is skipped, so however often the game
  # recomposes the corner label, nothing is allocated and nothing is written.
  if cur != want:
    gVerLabelAlloc = want
    let ns = verLabelNewString(cast[Il2CppPtr](0))
    if ns == nil or cIsReadable(ns, 0x14'i32) == 0'i32:
      warn "version label: the guarded il2cpp_string_new failed or returned " &
           "an unreadable String; the stock label is left alone"
      return
    if cUxWritePtr(self, verOff, ns) == 0'i32:
      warn "version label: _alphaVersionText (+0x" & hexOf(uint64(verOff)) &
           ") was not safely writable; the stock label is left alone"
      return
    gVerLabelApplied = want
    inc gVerLabelWrites
    okLog "version label: EFT.UI.PreloaderUI::_alphaVersionText (+0x" &
          hexOf(uint64(verOff)) & ") on this=0x" & hexOf(cast[uint64](self)) &
          " set to \"" & want & "\"; the original RefreshCornerLabel @ 0x" &
          hexOf(uint64(cVlbRva(VlbTRefresh))) & " will compose and repaint it " &
          "(write #" & $gVerLabelWrites & ")"

  # ---- the components we do not want appended ----
  #
  # The composer appends each of these behind its own null/empty test, so
  # nulling them makes the finished label EXACTLY the seed above -- no trailing
  # separator, no empty segment. That is the difference between "aowlspt |
  # aoughwl.com | 1.1.0.1.4677" and "aowlspt | aoughwl.com | 1.1.0.1.4677 | PvE".
  verLabelClear(self, cVlbOffSessionId(), "_sessionIdText")
  verLabelClear(self, cVlbOffCommits(), "_commitsNotMatchText")
  # `_sessionModeText` is the one exception, and it is a deliberate handover:
  # when `uxMenuModeText` is also on, THAT feature owns this field and is
  # actively driving it, so we leave it and the label reads
  # "<our format> | <the mode text>". With `uxMenuModeText` off there is nothing
  # driving it but the game's stock "PvE"/"PVE ZONE", which is exactly the
  # segment the user asked to be rid of.
  if not gModeTextOn:
    verLabelClear(self, cVlbOffSessionMode(), "_sessionModeText")

proc verLabelRefreshFired(regs: Il2CppPtr) =
  ## Dispatched by slot identity from `patchFired` for the kind=14 PREFIX detour
  ## on `EFT.UI.PreloaderUI::RefreshCornerLabel`. Runs on Unity's main thread,
  ## immediately before the original composes the label out of the fields this
  ## has just arranged. It never suppresses the original -- `patchFired` returns
  ## 0 for this slot -- and it never calls it.
  if gVerLabelOff:
    return
  inc gVerLabelFires
  let selfRaw = cRegsInt(regs, 0'i32)          # RCX = the PreloaderUI `this`
  if selfRaw == 0'u64:
    return
  let self = cast[Il2CppPtr](selfRaw)

  if gVerLabelFires == 1:
    let tid = int(cThreadId())
    okLog "version label: RefreshCornerLabel prefix first fired on thread " &
          $tid & (if tid == int(gHostThreadId):
                    " (HOST thread -- unexpected, NOT Unity's)"
                  else: " (Unity's main thread)")

  if cIsReadable(self, cVlbOffVersionText() + 8'i32) == 0'i32:
    return

  if cVlbBodyGuarded(self) == nil:
    inc gVerLabelFaults
    warn "version label: the guarded body faulted (" & $gVerLabelFaults &
         " of " & $VerLabelMaxFaults & ")"
    if gVerLabelFaults >= VerLabelMaxFaults:
      gVerLabelOff = true
      warn "version label: too many faults; switching itself off for this " &
           "session and leaving the stock label alone"

proc bindVerLabel(verbose: bool): bool =
  ## Installs the PREFIX detour on `EFT.UI.PreloaderUI::RefreshCornerLabel` from
  ## the verified static target. Opt-in (`uxVersionLabel`). A build whose
  ## prologue does not match binds nothing at all, so this is a no-op elsewhere
  ## rather than a hazard.
  ##
  ## NO CONTENTION TO DECLARE. Unlike `bindModeText`, this has no mutual
  ## exclusion to check and refuses nothing: `RefreshCornerLabel` is hooked by
  ## nothing else in this host. That is the main reason this feature chose it
  ## over `PreloaderUI::Update`, which the F3 overlay, the ESP probe and the
  ## menu mode text are already contending for.
  if gVerLabelSlot >= 0:
    return true
  if not gReady or gDisableDrain:
    return false
  let fn = cVlbFn(VlbTRefresh)
  if fn == nil:
    if verbose:
      info "version label: " & readCString(cVlbName(VlbTRefresh)) & " @ 0x" &
           hexOf(uint64(cVlbRva(VlbTRefresh))) &
           " did not verify on this build (" & $int(cVlbOkCount()) &
           " target(s) verified, " & $int(cVlbBadCount()) &
           " rejected); nothing bound"
    return false
  if attachDrain("EFT.UI.PreloaderUI::RefreshCornerLabel", fn,
                 cast[Il2CppMethod](0), false, verbose, 14'i32, false):
    okLog "version label armed on EFT.UI.PreloaderUI::RefreshCornerLabel " &
          "(prefix); the corner label will read \"" & gVerLabelFormat &
          "\" with {version} replaced by the client's own version, read live"
    return true
  result = false
