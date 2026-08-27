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
var gV2Dot: RvaTarget
var gOrtho: RvaTarget
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

  # THE 8-BYTE AGGREGATE SUBJECT. Vector2 is exactly 8 bytes, which is the one
  # size Win64 passes IN the register, and this method takes two of them.
  #
  #   48 83 EC 18        sub   rsp, 0x18
  #   48 89 54 24 38     mov   [rsp+0x38], rdx    <- stores RDX AS A VALUE
  #   48 89 0C 24        mov   [rsp+0x00], rcx    <- stores RCX AS A VALUE
  #   F3 0F 10 44 24 3C  movss xmm0, [rsp+0x3c]   <- rhs.y = byte 4 of RDX
  #   F3 0F 10 4C 24 38  movss xmm1, [rsp+0x38]   <- rhs.x = byte 0 of RDX
  #
  # It never dereferences either register. The mirror image of `Vector3::Dot`,
  # which does nothing else. `type 23032 --shared` reports no sharing.
  gV2Dot = rvaTarget(
    "UnityEngine.Vector2::Dot(Vector2,Vector2) -> float",
    0x529BB60'u32,
    "48 83 EC 18 48 89 54 24 38 48 89 0C 24 F3 0F 10",
    owners = 1)

  # THE SPILL SUBJECT. Returns a 64-byte Matrix4x4, so the shape is
  #   pos0 retbuf (RCX), pos1 left (XMM1), pos2 right (XMM2), pos3 bottom
  #   (XMM3), pos4 top, pos5 zNear, pos6 zFar, pos7 MethodInfo*
  # -- EIGHT slots, three of them float arguments on the STACK. The callee's
  # own frame fixes the caller layout beyond doubt: `push rbx; sub rsp,0x70`
  # puts the return address at rsp+0x78, and it then reads
  #   movss xmm3,[rsp+0xa0]  movss xmm1,[rsp+0xa8]  movss xmm0,[rsp+0xb0]
  # i.e. 32 bytes of shadow space above the return address, then 8-byte slots
  # in argument order. `type 23028 --shared` reports no sharing.
  gOrtho = rvaTarget(
    "UnityEngine.Matrix4x4::Ortho(l,r,b,t,zNear,zFar) -> Matrix4x4",
    0x5294C30'u32,
    "40 53 48 83 EC 70 48 8B 05 3B F5 E3 01 0F 57 C0",
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
  ## A 4-byte by-value aggregate must still be REFUSED. A refusal that never
  ## fires is not a refusal, and this check exists so the refusal path stays
  ## real now that the 8-byte case has been lifted out of it.
  ##
  ## It USED to assert on 8 bytes, and that was correct while 8 was unmeasured.
  ## It is measured now -- `checkVec2Dot` below -- so keeping this pointed at 8
  ## would have made the refusal path and the proof contradict each other, with
  ## both reporting PASS. 4 bytes is genuinely unmeasured on this build.
  var a = callArgs()
  var scratch: array[4, uint8] = [0'u8, 0'u8, 0'u8, 0'u8]
  a.addAggregate(cast[Il2CppPtr](addr scratch[0]), 4'i32)
  if a.bad:
    note(r, "refuses-unproven-size", pvPass,
      "a 4-byte by-value aggregate was refused: " & a.badWhy)
  else:
    note(r, "refuses-unproven-size", pvFail,
      "a 4-byte by-value aggregate was ACCEPTED. That size is still unmeasured " &
      "on this build and accepting it silently picks one of two conventions")

# ---------------------------------------------------------------------------
# Check 5 -- the 8-BYTE aggregate, which used to be the refused case.
# ---------------------------------------------------------------------------

proc checkVec2Dot(r: var ProofReport) =
  ## `Vector2::Dot((1,2),(3,4))` must be EXACTLY 11.0.
  ##
  ## 1*3 + 2*4 = 11, and every input and the output are exact in binary32, so
  ## this is equality and not a tolerance. The point is not the arithmetic: it
  ## is that the two arguments are 8-byte aggregates, and this build passes an
  ## 8-byte aggregate PACKED IN the register while it passes a 12-byte one by
  ## hidden pointer. Those are opposite conventions in one call table, which is
  ## why neither could be assumed from the other.
  ##
  ## This is the EXACT MIRROR of `checkRival`. There, packing a Vector3 into
  ## the register takes an access violation because the callee dereferences it.
  ## Here, packing a Vector2 into the register is the RIGHT answer -- and the
  ## negative control below is the other half of the mirror.
  var a = callArgs()
  a.addVec2(1.0, 2.0)
  a.addVec2(3.0, 4.0)
  let o = callFloat(gV2Dot, a)
  if o.kind == coRefused:
    note(r, "vec2/8-byte-in-register", pvInconclusive,
      "refused before calling: " & o.why)
    return
  if o.kind == coFaulted:
    note(r, "vec2/8-byte-in-register", pvFail,
      "the call FAULTED: " & o.why & " -- an access violation here means the " &
      "callee DID dereference its argument register, so an 8-byte aggregate " &
      "does NOT travel in the register on this build and the refusal should " &
      "be put back")
    return
  if o.f == 11.0:
    note(r, "vec2/8-byte-in-register", pvPass,
      "Dot((1,2),(3,4)) returned exactly 11.0 -- an 8-byte by-value aggregate " &
      "IS passed PACKED IN the integer-class register for its slot, first " &
      "field in the low half")
  else:
    note(r, "vec2/8-byte-in-register", pvFail,
      "Dot((1,2),(3,4)) returned a number that is not 11.0, and did not fault. " &
      "The 8-byte convention is wrong and the answer looked plausible")

proc checkVec2Rival(r: var ProofReport) =
  ## THE NEGATIVE CONTROL for the 8-byte case: make the SAME call the OTHER
  ## way -- by hidden pointer, the convention that is right for 12 bytes -- and
  ## require it does NOT return 11.0.
  ##
  ## The callee reads the register's own bits as two floats. Handed a pointer,
  ## it reads the low and high halves of an address as floats, which is a
  ## number and not a fault, so this control cannot be "passed" by a crash.
  ## If it returned 11.0 as well, the two conventions would be
  ## indistinguishable here and the check above would be worthless.
  var a = callArgs()
  # Staged through addOut, which does not consult the size classifier, so the
  # rival shape can be built even though addAggregate would now route 8 bytes
  # the other way. That is the point: a control has to be able to be wrong.
  # The cells are zeroed, so what the callee sees is the ADDRESS of a cell
  # reinterpreted as two floats -- never 11.0 for any address.
  let cl = a.addOut(8'i32)
  let cr = a.addOut(8'i32)
  if cl < 0'i32 or cr < 0'i32:
    note(r, "vec2-rival/negative-control", pvInconclusive,
      "the rival shape could not be staged: " & a.badWhy)
    return
  let o = callFloat(gV2Dot, a)
  if o.kind == coRefused:
    note(r, "vec2-rival/negative-control", pvInconclusive,
      "the rival call was refused rather than attempted (" & o.why &
      "), so nothing was ruled out")
    return
  if o.kind == coFaulted:
    note(r, "vec2-rival/negative-control", pvPass,
      "the by-pointer rival faulted rather than returning 11.0, so the " &
      "positive result above is not an artefact of a check that cannot fail")
    return
  if o.f == 11.0:
    note(r, "vec2-rival/negative-control", pvFail,
      "the by-POINTER rival ALSO returned 11.0. Both conventions cannot be " &
      "right, so this experiment cannot distinguish them and the 8-byte " &
      "question is NOT settled by it")
    return
  note(r, "vec2-rival/negative-control", pvPass,
    "the by-pointer rival returned something other than 11.0 (it read the " &
    "two halves of an address as floats), so the 8-byte result above is " &
    "falsifiable and was not falsified")

# ---------------------------------------------------------------------------
# Check 6 -- STACK SPILL, on a call that needs eight slots.
# ---------------------------------------------------------------------------

proc orthoDiag(r: var ProofReport; name: string;
               top, zNear, zFar: float; slots: int32;
               m00, m11, m22: var float; okAll: var bool): bool =
  ## One `Matrix4x4::Ortho` call, returning the three diagonal entries.
  ##
  ## `slots` is how many argument positions to declare. The correct number is
  ## 8; passing 7 is the negative control, and it deliberately leaves the
  ## MethodInfo* (NULL) sitting in zFar's stack slot.
  ##
  ## Diagonal entries only, and that is deliberate: m00/m11/m22/m33 sit at
  ## byte 0/20/40/60 whichever way round the storage is, because a diagonal is
  ## unchanged by transposition. Row-major-versus-column-major is a question
  ## this check does not have to answer and therefore cannot get wrong.
  ## (Measured anyway: boxed m00@0x10, m11@0x24, m22@0x38, m33@0x4c, so the
  ## unboxed payload is column-major and 64 bytes.)
  okAll = false
  m00 = 0.0
  m11 = 0.0
  m22 = 0.0
  var a = callArgs()
  let ret = a.addSret(64'i32)
  if ret < 0'i32:
    note(r, name, pvInconclusive, "no 64-byte return buffer: " & a.badWhy)
    return false
  a.addFloat(-1.0)      # pos1 left    -> XMM1
  a.addFloat(1.0)       # pos2 right   -> XMM2
  a.addFloat(-4.0)      # pos3 bottom  -> XMM3
  a.addFloat(top)       # pos4 top     -> [rsp+32]   THE FIRST SPILLED SLOT
  a.addFloat(zNear)     # pos5         -> [rsp+40]
  if slots >= 8'i32:
    a.addFloat(zFar)    # pos6         -> [rsp+48]
  if a.bad:
    note(r, name, pvInconclusive, "the argument pack refused: " & a.badWhy)
    return false
  let o = callVoid(gOrtho, a)
  if o.kind == coRefused:
    note(r, name, pvInconclusive, "refused before calling: " & o.why)
    return false
  if o.kind == coFaulted:
    note(r, name, pvFail, "the 8-slot call FAULTED: " & o.why)
    return false
  var k0 = false
  var k1 = false
  var k2 = false
  m00 = outFloat(ret, 0'i32, k0)
  m11 = outFloat(ret, 20'i32, k1)
  m22 = outFloat(ret, 40'i32, k2)
  okAll = k0 and k1 and k2
  if not okAll:
    note(r, name, pvInconclusive,
      "the return buffer could not be read back -- which is not the same " &
      "answer as zero and is not being reported as one")
    return false
  return true

proc checkSpill(r: var ProofReport) =
  ## `Ortho(-1, 1, -4, 4, -16, 16)` on EIGHT slots, three of them on the stack.
  ##
  ## An orthographic projection maps [left,right] onto a fixed range in x and
  ## [bottom,top] onto the same range in y, so its x and y diagonal entries are
  ## 2/(right-left) and 2/(top-bottom) in every convention there is -- GL, D3D
  ## and Vulkan alike. With these inputs that is 2/2 = 1 and 2/8 = 0.25, both
  ## exact in binary32.
  ##
  ## **m11 == 0.25 is the spill claim**, and it is the whole check: `bottom` is
  ## the last register argument and `top` is the FIRST STACK ARGUMENT. If the
  ## shadow space were 16 bytes instead of 32, or the slot stride 4 instead of
  ## 8, or the arguments in the wrong order, `top` would not be 4.0 and m11
  ## would not be 0.25. It is also a float in a spilled position, which is the
  ## one thing `tools/gen_fast_table.py` derives rather than measures.
  ##
  ## m00 == 1.0 is the control on the register half of the same call.
  ##
  ## The z entry is reported by MAGNITUDE only: |m22| = 2/(zFar-zNear) =
  ## 0.0625 for a GL-style depth range, and the SIGN and a D3D-style 1/(f-n)
  ## are both live conventions that this experiment is not testing and will
  ## not pretend to have tested. A |m22| of 0.03125 is reported INCONCLUSIVE
  ## and named, not quietly failed.
  var m00 = 0.0
  var m11 = 0.0
  var m22 = 0.0
  var ok = false
  if not orthoDiag(r, "spill/8-slot", 4.0, -16.0, 16.0, 8'i32, m00, m11, m22, ok):
    return
  if m00 != 1.0:
    note(r, "spill/8-slot", pvFail,
      "m00 is not 1.0, so the REGISTER half of an 8-slot call is already " &
      "wrong and the stack half cannot be read into")
    return
  if m11 != 0.25:
    note(r, "spill/8-slot", pvFail,
      "m00 is 1.0 but m11 is not 0.25. The register arguments arrived and " &
      "the FIRST STACKED argument did not: `top` is not reaching [rsp+32]. " &
      "This is the shadow-space/stride/order failure, and it did not fault")
    return
  var mag = m22
  if mag < 0.0: mag = -mag
  if mag != 0.0625:
    if mag == 0.03125:
      note(r, "spill/8-slot", pvInconclusive,
        "m00 and m11 are exactly right, so the first stacked argument DID " &
        "arrive -- but |m22| is 0.03125, i.e. 1/(zFar-zNear) rather than " &
        "2/(zFar-zNear). That is a depth-range convention this check does not " &
        "test, not a spill failure; the last two stack slots are unproven here")
      return
    note(r, "spill/8-slot", pvFail,
      "m00 and m11 are right but |m22| is neither 0.0625 nor 0.03125, so " &
      "`zNear`/`zFar` -- stack slots 2 and 3 -- did not arrive")
    return
  note(r, "spill/8-slot", pvPass,
    "Ortho(-1,1,-4,4,-16,16) on EIGHT slots returned m00=1.0, m11=0.25 and " &
    "|m22|=0.0625 exactly -- three float arguments crossed the 32-byte shadow " &
    "space into [rsp+32], [rsp+40], [rsp+48] in order, and a spilled float " &
    "carried in the low half of an 8-byte slot is read correctly")

proc checkSpillControl(r: var ProofReport) =
  ## THE NEGATIVE CONTROL for spill: make the SAME call one slot SHORT.
  ##
  ## Declaring 7 positions instead of 8 leaves the trailing MethodInfo* -- NULL
  ## -- in the stack slot `zFar` should have occupied, so the callee reads
  ## zFar as 0.0. The range becomes 0-(-16) = 16, and |m22| becomes 0.125
  ## rather than 0.0625, while m00 and m11 stay exactly right.
  ##
  ## That is a very specific prediction and it is the point. If the stack
  ## layout in `aowlspt_fast.h` were wrong, a one-slot change would not move
  ## exactly one entry by exactly a factor of two while leaving the others
  ## alone. And it is safe: pure arithmetic, no dereference, no game state.
  var m00 = 0.0
  var m11 = 0.0
  var m22 = 0.0
  var ok = false
  if not orthoDiag(r, "spill-short/negative-control", 4.0, -16.0, 0.0, 7'i32,
                   m00, m11, m22, ok):
    return
  var mag = m22
  if mag < 0.0: mag = -mag
  if m11 != 0.25:
    note(r, "spill-short/negative-control", pvInconclusive,
      "the one-slot-short call did not even reproduce m11 = 0.25, so it is " &
      "not isolating the last stack slot and rules nothing out")
    return
  if mag == 0.0625:
    note(r, "spill-short/negative-control", pvFail,
      "dropping the LAST stack argument changed nothing: |m22| is still " &
      "0.0625. The 8-slot result above is therefore not evidence that the " &
      "last stack slot is read at all -- a check that cannot fail")
    return
  if mag == 0.125:
    note(r, "spill-short/negative-control", pvPass,
      "one slot short, the callee read zFar as 0.0 and |m22| became exactly " &
      "0.125 -- twice 0.0625, exactly as a range of 16 instead of 32 predicts " &
      "-- while m11 stayed 0.25. Stack slot POSITION is what is being proved, " &
      "not merely that some bytes arrived")
    return
  note(r, "spill-short/negative-control", pvPass,
    "one slot short, |m22| moved off 0.0625, so the last stack slot is really " &
    "read and the 8-slot result is falsifiable (the value was not the 0.125 " &
    "predicted, which is worth noting but does not weaken the 8-slot PASS)")

proc checkStackIntact(r: var ProofReport) =
  ## After the spilled calls, the ORIGINAL five-slot proof must still hold.
  ##
  ## A mis-modelled stack does not always show up in the callee's answer; it
  ## shows up in the CALLER afterwards. `Dot((1,2,3),(4,5,6))` was exactly 32.0
  ## before any spilled call was made, and if it is not exactly 32.0 after
  ## them, something the spilled calls did outlived them.
  var a = callArgs()
  a.addVec3(1.0, 2.0, 3.0)
  a.addVec3(4.0, 5.0, 6.0)
  let o = callFloat(gDot, a)
  if o.kind != coOk:
    note(r, "spill/stack-intact", pvFail,
      "after the spilled calls, the plain 5-slot call no longer even runs: " & o.why)
    return
  if o.f == 32.0:
    note(r, "spill/stack-intact", pvPass,
      "the plain 5-slot Dot still returns exactly 32.0 after three spilled " &
      "calls, so nothing those calls did to the stack outlived them")
  else:
    note(r, "spill/stack-intact", pvFail,
      "the plain 5-slot Dot returned something other than 32.0 AFTER the " &
      "spilled calls, having returned 32.0 before them. The spilled call " &
      "shape damaged something that outlived it")

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
  checkVec2Dot(result)
  checkSpill(result)
  checkSpillControl(result)
  checkStackIntact(result)
  if includeRival:
    checkRival(result)
    checkVec2Rival(result)
  else:
    note(result, "rival/negative-control", pvInconclusive,
      "not run (the rival control is separately gated), so the positive " &
      "results above are unfalsified")

  # A fault beyond the one the rival control expects is a reason to stay off.
  # TWO controls are now allowed to fault, not one: `checkRival` is expected
  # to, and `checkVec2Rival` is allowed to (it reads an address as two floats,
  # which normally returns a number, but a fault there is a PASS for it too).
  # An allowance that is too tight self-disables the module on a healthy run.
  let extra = faultCount() - faultsBefore - (if includeRival: 2'i32 else: 0'i32)
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
    result.verdict = "call-proof: VERDICT aggregates WIDER than 8 bytes pass " &
      "BY HIDDEN POINTER and aggregates of EXACTLY 8 bytes pass PACKED IN the " &
      "register; sret is (retbuf RCX, this/arg0 RDX, ...); and arguments past " &
      "position 3 SPILL to 8-byte stack slots above a 32-byte shadow area, " &
      "proven to 8 slots -- " &
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
