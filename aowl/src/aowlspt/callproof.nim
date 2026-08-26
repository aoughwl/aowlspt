## THE LIVE EXPERIMENT that settles the by-value aggregate convention.
##
## WHY AN EXPERIMENT AT ALL, WHEN THE BYTES ALREADY SAY SO
## ------------------------------------------------------
## `abi/aowlspt_callrva.h` records the callee's own instructions from four
## methods on this build. Those bytes are strong: they are what the CPU will
## execute, not an inference about it. But they establish what the CALLEE
## expects, and not that OUR CALLER produces it. The two are different claims
## and only one of them has been tested. CLAUDE.md 9b: an offline disassembly
## proof once established, correctly, which field `SetGameModeText` writes --
## and could not establish that the field reaches the screen. It did not.
##
## THE TRAP THIS IS BUILT AROUND
## -----------------------------
## **"The call returned without faulting" is NOT evidence.** A wrong convention
## returns plausible garbage, and that is the single most expensive class of bug
## in this project. `Physics::Raycast` would be the worst possible subject: it
## returns a `bool`, and a `bool` from a completely wrong call is
## indistinguishable from a `bool` from a right one.
##
## So the subject is a method whose answer is known EXACTLY, in advance, by
## arithmetic nobody has to trust:
##
##   UnityEngine.Vector3::Dot((1,2,3), (4,5,6))   = 4 + 10 + 18 = 32.0
##   UnityEngine.Vector3::Cross((1,2,3), (4,5,6)) = (-3, 6, -3)
##
## Every one of those inputs and outputs is exactly representable in binary32,
## so the assertion is EQUALITY, not a tolerance. There is no arrangement of
## registers other than the right one that produces 32.0 and (-3,6,-3).
##
## AND IT CAN FAIL. `checkRival` deliberately makes the SAME call under the
## rival convention -- the 12 bytes packed into the registers themselves rather
## than passed by pointer -- and requires that it does NOT return 32.0. If both
## conventions returned 32.0 the experiment would be a check that cannot fail,
## and this reports INCONCLUSIVE rather than claiming a pass. That is the whole
## design: describe the input that makes the check fail, or you have not written
## a check.
##
## WHY IT IS SAFE TO RUN ON A LIVE CLIENT
## --------------------------------------
## * `Vector3::Dot` and `Vector3::Cross` are PURE ARITHMETIC on two buffers this
##   module owns. They touch no game state, allocate nothing, and have no side
##   effect of any kind. There is nothing for a wrong answer to damage.
## * No `GameWorld`, no camera, no raid, no UI, no live object. It runs at the
##   main menu, at profile-select, anywhere. It never gates on
##   `whenReady("EFT.GameWorld")` -- fact #141, a check that cannot fail, which
##   killed the FOV mod again at 8.375s while logging "the game world is up"
##   from the character screen.
## * The rival-convention call dereferences a float bit pattern as an address.
##   That is an access violation by design, and it runs inside the ONE guard in
##   `aowlspt_callrva.h`, which catches it and returns `coFaulted`. A caught AV
##   is the EXPECTED reading for that check, not a crash.
## * Default OFF, runs ONCE, and self-disables permanently after the first
##   fault beyond the one the rival check expects.
##
## HOW THE COORDINATING SESSION RUNS IT
## ------------------------------------
## Flag: **`callProof`**, default off. Set it with
## `python tools/hostcfg.py set callProof on` -- never by hand-editing
## `aowlspt-host.json`, because `hostcfg.py` checks the key against what is
## actually read and a typo otherwise produces a flag nobody consumes.
##
## Then read the verdict with `python tools/hostlog.py grep "call-proof"`.
## Every line is prefixed `call-proof:` and every check reports exactly one of
## PASS / FAIL / INCONCLUSIVE. The summary line is the answer:
##
##   `call-proof: VERDICT by-value aggregates pass BY HIDDEN POINTER -- 5 PASS, 0 FAIL, 0 INCONCLUSIVE`
##
## Any FAIL, or any INCONCLUSIVE, means the convention is NOT settled and
## nothing downstream should be built on it. There is no fourth outcome and no
## silent one.

import aowlspt/il2cpp
import aowlspt/callrva

# ---------------------------------------------------------------------------
# The targets.
#
# Every RVA and every prologue byte below is COPIED from, and reproducible with:
#
#   python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \
#          .cache/global-metadata.dec.dat bytes <RVA> 16
#
# and the signature + owner count from `... type 23029 --shared`. Nothing here
# was typed from memory and nothing was inferred from a method NAME.
# ---------------------------------------------------------------------------

## DECLARED BARE AND ASSIGNED IN A PROC -- NOT `var g = rvaTarget(...)`.
##
## This is the defect the first live run found. In a nimony `--app:lib` build a
## global initialised by a CALL is silently left zeroed, which `aowlspt/fast`
## documents as its first non-negotiable rule and which this file broke anyway.
## The live client reported
##
##     INCONCLUSIVE verifier -- ... @0x0: no prologue was declared
##
## and that message was TRUE and was not the cause: the whole object was zero,
## including the name, which is why the line began with a blank. `looksZeroed`
## in `aowlspt/callrva` now names this trap outright, and `describe` prints the
## module base beside the resolved address so a zero on one side can never be
## read as a zero on the other.
var gDot: RvaTarget
var gCross: RvaTarget
var gWrongSig: RvaTarget
var gTargetsReady = false

proc initTargets() =
  ## Assign the targets. Called from the run, never at module scope.
  if gTargetsReady: return
  gTargetsReady = true

  gDot = rvaTarget(
    "UnityEngine.Vector3::Dot(Vector3,Vector3) -> float",
    0x5297BF0'u32,
    # 66 90 | movss xmm0,[rcx+4] | mulss xmm0,[rdx+4] | movss xmm1,[rcx]
    "66 90 F3 0F 10 41 04 F3 0F 59 42 04 F3 0F 10 09",
    owners = 1)

  gCross = rvaTarget(
    "UnityEngine.Vector3::Cross(Vector3,Vector3) -> Vector3",
    0x5297A60'u32,
    # movss xmm3,[rdx+4] | movss xmm0,[rdx+8] | mulss xmm0,[r8+4]
    "F3 0F 10 5A 04 F3 0F 10 42 08 F3 41 0F 59 40 04",
    owners = 1)

  # The same RVA with ONE byte of the declared prologue flipped. This exists so
  # that "the verify passed" is a claim that can be falsified: if this one ALSO
  # verifies, the verifier is not comparing anything and every other PASS in
  # this file is worthless.
  gWrongSig = rvaTarget(
    "UnityEngine.Vector3::Dot [DELIBERATELY WRONG PROLOGUE]",
    0x5297BF0'u32,
    "67 90 F3 0F 10 41 04 F3 0F 59 42 04 F3 0F 10 09",
    owners = 1)

type
  ProofOutcome* = enum
    pvPass
    pvFail
    pvInconclusive

  ProofLine* = object
    name*: string
    outcome*: ProofOutcome
    detail*: string

  ProofReport* = object
    lines*: seq[ProofLine]
    passes*: int32
    fails*: int32
    inconclusive*: int32
    verdict*: string
    wiring*: string
      ## The resolved address, the module base and the declared prologue
      ## length, printed every run so a zero can never be ambiguous again.

proc note(r: var ProofReport; name: string; o: ProofOutcome; detail: string) =
  r.lines.add ProofLine(name: name, outcome: o, detail: detail)
  if o == pvPass: r.passes = r.passes + 1'i32
  elif o == pvFail: r.fails = r.fails + 1'i32
  else: r.inconclusive = r.inconclusive + 1'i32

proc tag*(o: ProofOutcome): string =
  case o
  of pvPass: "PASS"
  of pvFail: "FAIL"
  of pvInconclusive: "INCONCLUSIVE"

# ---------------------------------------------------------------------------
# Check 1 -- the verifier can say no.
# ---------------------------------------------------------------------------

proc checkVerifierWorks(r: var ProofReport) =
  ## Two verifies of the SAME address: the real prologue must verify and the
  ## one-byte-wrong prologue must be REFUSED with a mismatch. A verifier that
  ## passes both is not comparing bytes, and every later PASS would be noise.
  let good = verify(gDot)
  let bad = verify(gWrongSig)
  if good.kind != coOk:
    note(r, "verifier", pvInconclusive,
      "the real prologue did not verify, so nothing below could be attempted: " & good.why)
    return
  if bad.kind == coOk:
    note(r, "verifier", pvFail,
      "a DELIBERATELY WRONG prologue verified at the same address -- the byte " &
      "compare is not comparing anything, and no other result in this run means anything")
    return
  note(r, "verifier", pvPass,
    "the real prologue verified and a one-byte-wrong one was refused (" & bad.why & ")")

# ---------------------------------------------------------------------------
# Check 2 -- the by-value convention, with an answer known in advance.
# ---------------------------------------------------------------------------

proc checkDot(r: var ProofReport) =
  ## `Dot((1,2,3),(4,5,6))` must be EXACTLY 32.0.
  ##
  ## Not "roughly 32", not "not NaN", not "it returned". 4+10+18 is exact in
  ## binary32 and so are all six inputs, so the assertion is equality. No
  ## wrong register arrangement produces 32.0: swap the operands and it is
  ## still 32 (dot is symmetric -- which is why the ASYMMETRIC `Cross` check
  ## below is also run), but pass the floats themselves instead of pointers and
  ## the callee dereferences 0x3F800000.
  var a = callArgs()
  a.addVec3(1.0, 2.0, 3.0)
  a.addVec3(4.0, 5.0, 6.0)
  let o = callFloat(gDot, a)
  if o.kind == coRefused:
    note(r, "dot/by-value", pvInconclusive, "refused before calling: " & o.why)
    return
  if o.kind == coFaulted:
    note(r, "dot/by-value", pvFail,
      "the call FAULTED under the by-hidden-pointer convention: " & o.why &
      " -- the convention the header claims to have measured is wrong")
    return
  if o.f == 32.0:
    note(r, "dot/by-value", pvPass,
      "Dot((1,2,3),(4,5,6)) returned exactly 32.0 -- a by-value Vector3 " &
      "argument IS passed by hidden pointer in the integer-class register for its slot")
  else:
    note(r, "dot/by-value", pvFail,
      "Dot((1,2,3),(4,5,6)) returned a number that is not 32.0. The call did " &
      "not fault, which is exactly why a returned-without-faulting check is " &
      "worthless: the convention is wrong and the answer looked plausible")

proc checkCross(r: var ProofReport) =
  ## `Cross((1,2,3),(4,5,6))` must be EXACTLY (-3, 6, -3), read out of the
  ## hidden return buffer.
  ##
  ## This is the ASYMMETRIC companion to `Dot`, and it is not redundant: cross
  ## product ANTI-commutes, so an implementation that had the two arguments in
  ## the wrong registers would return (3,-6,3) -- a number that passes every
  ## sanity check anyone would think to write, and is the negation of the truth.
  ## Sign is the whole point of this check.
  ##
  ## It simultaneously tests the sret shape: slot 0 is the return buffer, and
  ## the arguments shift one register right because of it.
  var a = callArgs()
  let ret = a.addSret(12'i32)
  if ret < 0'i32:
    note(r, "cross/sret", pvInconclusive, "no return buffer: " & a.badWhy)
    return
  a.addVec3(1.0, 2.0, 3.0)
  a.addVec3(4.0, 5.0, 6.0)
  let o = callVoid(gCross, a)
  if o.kind == coRefused:
    note(r, "cross/sret", pvInconclusive, "refused before calling: " & o.why)
    return
  if o.kind == coFaulted:
    note(r, "cross/sret", pvFail, "the sret call FAULTED: " & o.why)
    return
  var okx = false
  var oky = false
  var okz = false
  let x = outFloat(ret, 0'i32, okx)
  let y = outFloat(ret, 4'i32, oky)
  let z = outFloat(ret, 8'i32, okz)
  if not (okx and oky and okz):
    note(r, "cross/sret", pvInconclusive,
      "the return buffer could not be read back -- which is not the same " &
      "answer as (0,0,0) and is not being reported as one")
    return
  if x == -3.0 and y == 6.0 and z == -3.0:
    note(r, "cross/sret", pvPass,
      "Cross((1,2,3),(4,5,6)) wrote exactly (-3,6,-3) into the hidden buffer " &
      "-- sret is (retbuf RCX, arg0 RDX, arg1 R8, MethodInfo* R9), and the " &
      "argument ORDER is right, not merely the magnitudes")
  elif x == 3.0 and y == -6.0 and z == 3.0:
    note(r, "cross/sret", pvFail,
      "Cross returned (3,-6,3) -- the exact NEGATION of the right answer, so " &
      "the two arguments are in each other's registers. This is the failure " &
      "a magnitude-only check would have passed")
  else:
    note(r, "cross/sret", pvFail,
      "Cross did not write (-3,6,-3); the sret shape or the argument shape is wrong")

# ---------------------------------------------------------------------------
# Check 3 -- THE NEGATIVE CONTROL. Can this experiment fail at all?
# ---------------------------------------------------------------------------

proc checkRival(r: var ProofReport) =
  ## Make the SAME call under the RIVAL convention and require that it does NOT
  ## return 32.0.
  ##
  ## The rival is "an aggregate travels IN the register" -- so slot 0 carries
  ## the bit pattern of (1.0f, 2.0f) packed into 64 bits and slot 1 carries
  ## (4.0f, 5.0f). If `Dot` is really reading `[rcx]` and `[rdx]` then this
  ## dereferences 0x400000003F800000, takes an access violation, and the guard
  ## catches it. That caught fault is the EXPECTED and PASSING reading here.
  ##
  ## Without this check the experiment would be a self-comparison: "I called it
  ## the way I believe is right and got the answer I expected." This is the
  ## input that makes the check fail, and it is run rather than described.
  var a = callArgs()
  a.addInt(0x400000003F800000'i64)   # (1.0f, 2.0f) packed, the rival shape
  a.addInt(0x40A0000040800000'i64)   # (4.0f, 5.0f) packed
  let o = callFloat(gDot, a)
  if o.kind == coFaulted:
    note(r, "rival/negative-control", pvPass,
      "the rival convention took an access violation and the guard caught it " &
      "-- the callee really does dereference its argument registers, and this " &
      "experiment is capable of failing")
    return
  if o.kind == coRefused:
    note(r, "rival/negative-control", pvInconclusive,
      "the rival call was refused rather than attempted (" & o.why &
      "), so nothing was ruled out")
    return
  if o.f == 32.0:
    note(r, "rival/negative-control", pvFail,
      "the RIVAL convention also returned 32.0. Both conventions cannot be " &
      "right, so this experiment cannot distinguish them and the by-value " &
      "question is NOT settled by it")
    return
  note(r, "rival/negative-control", pvPass,
    "the rival convention returned something other than 32.0, so the positive " &
    "result above is not an artefact of a check that cannot fail")

# ---------------------------------------------------------------------------
# Check 4 -- the refusal path is real, not decorative.
# ---------------------------------------------------------------------------

proc checkRefusesUnproven(r: var ProofReport) =
  ## An 8-byte by-value aggregate must be REFUSED, because that is the one size
  ## Win64 passes in the register itself and no such argument has been measured
  ## on this build. A refusal that never fires is not a refusal.
  var a = callArgs()
  var scratch: array[8, uint8] = [0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0'u8]
  a.addAggregate(cast[Il2CppPtr](addr scratch[0]), 8'i32)
  if a.bad:
    note(r, "refuses-unproven-size", pvPass,
      "an 8-byte by-value aggregate was refused: " & a.badWhy)
  else:
    note(r, "refuses-unproven-size", pvFail,
      "an 8-byte by-value aggregate was ACCEPTED. That size is the unproven " &
      "case and accepting it silently picks one of two conventions")

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

var gRan = false
var gDisabled = false

proc callProofDisabled*(): bool = gDisabled

proc runCallProof*(includeRival: bool = true): ProofReport =
  ## Run the whole experiment ONCE. A second call returns an empty report
  ## rather than repeating game calls -- nothing here is a per-frame path and
  ## nothing about it needs to be.
  result = ProofReport(lines: @[], passes: 0'i32, fails: 0'i32,
                       inconclusive: 0'i32, verdict: "", wiring: "")
  if gRan or gDisabled:
    result.verdict = "call-proof: already run this session; not repeating"
    return
  gRan = true
  initTargets()

  # State the wiring BEFORE anything is attempted. The first live run reported
  # "@0x0" and it took a whole client start to learn whether that meant a
  # zeroed target, an unloaded module, or a bad address. This line answers all
  # three, every run, pass or fail.
  result.wiring = "call-proof: wiring " & describe(gDot)

  let faultsBefore = faultCount()

  checkVerifierWorks(result)
  if result.fails > 0'i32 or result.inconclusive > 0'i32:
    # The verifier is the foundation. If it did not hold, calling anything
    # would be building a result on an unchecked address, so stop -- and say
    # INCONCLUSIVE rather than reporting the checks that were never run as
    # anything at all.
    result.verdict = "call-proof: VERDICT INCONCLUSIVE -- the byte verifier " &
      "did not hold, so no call was attempted"
    gDisabled = true
    return

  checkRefusesUnproven(result)
  checkDot(result)
  checkCross(result)
  if includeRival:
    checkRival(result)
  else:
    note(result, "rival/negative-control", pvInconclusive,
      "not run (the rival control is separately gated), so the positive " &
      "results above are unfalsified")

  # A fault beyond the one the rival control expects is a reason to stay off.
  let extra = faultCount() - faultsBefore - (if includeRival: 1'i32 else: 0'i32)
  if extra > 0'i32:
    gDisabled = true

  if result.fails > 0'i32:
    result.verdict = "call-proof: VERDICT FAILED -- the by-value convention is " &
      "NOT what the header claims; build nothing on it. " &
      $result.passes & " PASS, " & $result.fails & " FAIL, " &
      $result.inconclusive & " INCONCLUSIVE"
    gDisabled = true
  elif result.inconclusive > 0'i32:
    result.verdict = "call-proof: VERDICT INCONCLUSIVE -- not every check could " &
      "be made, and 'I could not look' is not a pass. " &
      $result.passes & " PASS, " & $result.fails & " FAIL, " &
      $result.inconclusive & " INCONCLUSIVE"
  else:
    result.verdict = "call-proof: VERDICT by-value aggregates pass BY HIDDEN " &
      "POINTER, and sret is (retbuf RCX, this/arg0 RDX, ...) -- " &
      $result.passes & " PASS, " & $result.fails & " FAIL, " &
      $result.inconclusive & " INCONCLUSIVE"

proc formatCallProof*(r: ProofReport): seq[string] =
  ## One line per check plus the verdict, ready to hand to a mod's logger. Every
  ## line carries its own outcome word so `hostlog.py grep call-proof` shows the
  ## whole result and not just the happy summary.
  result = @[]
  if r.wiring.len > 0:
    result.add r.wiring
  var i = 0
  while i < r.lines.len and i < 32:
    let l = r.lines[i]
    result.add "call-proof: " & tag(l.outcome) & " " & l.name & " -- " & l.detail
    inc i
  result.add r.verdict
