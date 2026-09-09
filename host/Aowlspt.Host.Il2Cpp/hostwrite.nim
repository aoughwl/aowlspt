# hostwrite.nim -- the ONE gate every host write into managed memory goes
# through, plus the trace that lets the NEXT crash dump be matched to a write.
#
# `include`d into `aowlhost.nim` (NOT imported) so it shares the log helpers
# (`okLog`/`warn`/`info`), `hexOf`, and `readBoolKey`. It is included AFTER
# `nativeui.nim`, because it needs three things from there that cannot be
# re-derived here: `nuKlassOf`, `nuAlive` and `nuActiveInHierarchy`.
#
# THE MEASUREMENT THAT MOTIVATES IT (2026-09-02, tools/dmpread.py + capstone)
# --------------------------------------------------------------------------
#   Crash_2026-09-02_131229783  EFT.UI.SeasonWidgetData::From, Rax = 1 at
#                               `mov r8,[rax+0x20]` -- the Profile argument was
#                               the INTEGER 1.
#   Crash_2026-09-02_161150163  same From, +0x11f,
#                               `cmp qword [rbx+0x118], r12`, rbx = -1; the
#                               reference came from
#                               MainMenuBaseScreenController.Profile@0x58.
#
# Two different managed REFERENCE slots holding small integers, both on the
# menu re-show right after the player closed Settings. A served payload cannot
# do that; only a native store into the wrong object can.
#
# WHY EVERY EXISTING GUARD MISSED IT
# ----------------------------------
# The host's write guards are all READABILITY tests -- `aowl_is_readable`,
# `duOk`, `nuOk`: non-null plus VirtualQuery. On the IL2CPP GC heap that test
# CANNOT FAIL. The pages stay committed after an object dies, so a stale
# pointer into recycled memory answers "readable" every single time, and the
# write lands in whichever type now owns the address. A verification that
# cannot fail IS the bug (CLAUDE.md 9b) -- and this one had no input that could
# falsify it.
#
# Readability is necessary and NOT sufficient. A receiver must additionally
# answer:
#
#   1. KLASS   -- is `*(void**)recv` still the Il2CppClass* recorded when this
#                 pointer was CAPTURED? This is the question that catches GC
#                 recycling into a different type, i.e. the crash above.
#   2. BOUND   -- is the offset inside the receiver's instance size? (Refused
#                 when the size is unknown; see aowlspt_hostwrite.h for why the
#                 size is an argument and not a struct read.)
#   3. LIVE    -- does Unity's own `Object::op_Implicit` still say true?
#                 `nuAlive`. A Destroyed object keeps a managed shell that
#                 reads back perfectly and answers FALSE here. This is the only
#                 test that distinguishes "closed the screen" from "still open",
#                 and nothing on the write paths was asking it.
#
# WHAT THIS FILE DOES NOT CLAIM
# -----------------------------
# It does not claim to have found the write. It makes the write IMPOSSIBLE for
# the receivers that route through it, and it makes every route that still
# refuses SAY SO with a file:line site name -- so the next dump is matched to a
# logged site instead of being re-derived from disassembly.

# The header itself is emitted from `aowlhost.nim` alongside the other abi
# includes, so there is ONE place that fixes header order.

# ---- the gate and the stores (abi/aowlspt_hostwrite.h) --------------------
proc cHwRecvOk(recv, wantKlass: Il2CppPtr; off, n: int32;
               instSize: uint32): int32 {.importc: "aowl_hw_recv_ok", nodecl.}
proc cHwRecvKlassOk(recv, wantKlass: Il2CppPtr): int32 {.
  importc: "aowl_hw_recv_klass_ok", nodecl.}
proc cHwStoreU8(recv, wantKlass: Il2CppPtr; off: int32; instSize: uint32;
                v: uint8): int32 {.importc: "aowl_hw_store_u8", nodecl.}
proc cHwStoreI32(recv, wantKlass: Il2CppPtr; off: int32; instSize: uint32;
                 v: int32): int32 {.importc: "aowl_hw_store_i32", nodecl.}
proc cHwStoreI64(recv, wantKlass: Il2CppPtr; off: int32; instSize: uint32;
                 v: int64): int32 {.importc: "aowl_hw_store_i64", nodecl.}
proc cHwStoreF32(recv, wantKlass: Il2CppPtr; off: int32; instSize: uint32;
                 v: float32): int32 {.importc: "aowl_hw_store_f32", nodecl.}
proc cHwStorePtr(recv, wantKlass: Il2CppPtr; off: int32; instSize: uint32;
                 v: Il2CppPtr): int32 {.importc: "aowl_hw_store_ptr", nodecl.}
proc cHwAllowed(): int64 {.importc: "aowl_hw_allowed", nodecl.}
proc cHwRefused(): int64 {.importc: "aowl_hw_refused", nodecl.}
proc cHwRefusedKlass(): int64 {.importc: "aowl_hw_refused_klass", nodecl.}
proc cHwRefusedSize(): int64 {.importc: "aowl_hw_refused_size", nodecl.}
proc cHwRefusedMem(): int64 {.importc: "aowl_hw_refused_mem", nodecl.}

# ---- the trace ------------------------------------------------------------
## Default OFF (rule 5). `python tools/hostcfg.py set hostWriteTrace on`.
const HwTracePerSite = 8      ## first N writes logged per site, then silence
const HwRefusePerSite = 4     ## first N refusals logged per site
const HwMaxSites = 64

var gHwTraceOn = false
var gHwTraceRead = false
var gHwSite: seq[string] = @[]
var gHwSaidOk: seq[int32] = @[]
var gHwSaidNo: seq[int32] = @[]

proc hwTraceOn(): bool =
  ## Read once. The flag is a preference and is not consulted per write.
  if not gHwTraceRead:
    gHwTraceRead = true
    gHwTraceOn = readBoolKey("hostWriteTrace")
    if gHwTraceOn:
      okLog "hostWrite: TRACE IS ON. Every gated write logs (site, receiver, " &
            "klass wanted/got, offset, value) for its first " &
            $HwTracePerSite & " writes, and every REFUSAL for its first " &
            $HwRefusePerSite & ". Match the next crash dump's Rax/Rbx " &
            "against these receiver addresses."
  gHwTraceOn

proc hwSiteIdx(site: string): int =
  ## Capped registry (rule 4). Returns -1 when full, which only suppresses
  ## logging -- never the gate.
  var i = 0
  while i < gHwSite.len and i < HwMaxSites:
    if gHwSite[i] == site: return i
    i = i + 1
  if gHwSite.len >= HwMaxSites: return -1
  gHwSite.add site
  gHwSaidOk.add 0'i32
  gHwSaidNo.add 0'i32
  gHwSite.len - 1

proc hwSay(site: string; recv, want, got: Il2CppPtr; off: int32;
           val: string; ok: bool; why: string) =
  let idx = hwSiteIdx(site)
  if idx < 0: return
  if ok:
    if not hwTraceOn(): return
    if gHwSaidOk[idx] >= HwTracePerSite: return
    gHwSaidOk[idx] = gHwSaidOk[idx] + 1'i32
    okLog "hostWrite[" & site & "]: recv=" & hexOf(cast[uint64](recv)) &
          " klass=" & hexOf(cast[uint64](got)) & " (wanted " &
          hexOf(cast[uint64](want)) & ") +0x" & hexOf(uint64(off)) & " = " & val &
          " -- ALLOWED (" & $gHwSaidOk[idx] & "/" & $HwTracePerSite & ")"
  else:
    # A REFUSAL IS LOGGED WHETHER OR NOT THE TRACE FLAG IS ON. A silently
    # declining feature is the worst outcome we produce, and this particular
    # refusal is the one that says a corrupting write was stopped.
    if gHwSaidNo[idx] >= HwRefusePerSite: return
    gHwSaidNo[idx] = gHwSaidNo[idx] + 1'i32
    # THE KLASS CLAUSE MUST DESCRIBE THE KLASS, NOT THE REFUSAL.
    # MEASURED 2026-09-04 (tools/hostlog.py grep, boot 6bd304e3): four
    # modsReassertLabels refusals printed "klass=1d72283cda0 but wanted
    # 1d72283cda0" -- the two EQUAL. The gate was right; those were the
    # DESTROYED-object branch. "but wanted" asserts a klass mismatch that did
    # not happen, and it was read as a comparison bug in a gate that has none.
    # A refusal line now states which of the two facts is true, so the reason
    # in the message can be checked against the numbers in the message.
    let kl =
      if got == want:
        " klass=" & hexOf(cast[uint64](got)) &
        " (MATCHES the one recorded at capture -- this refusal is NOT about " &
        "the klass)"
      elif want == nil:
        " klass=" & hexOf(cast[uint64](got)) & " (none was recorded to want)"
      else:
        " klass=" & hexOf(cast[uint64](got)) & " but wanted " &
        hexOf(cast[uint64](want))
    warn "hostWrite[" & site & "] REFUSED: recv=" & hexOf(cast[uint64](recv)) &
         kl & "; +0x" & hexOf(uint64(off)) & " = " & val &
         " -- " & why & ". NOTHING WAS WRITTEN. (" & $gHwSaidNo[idx] & "/" &
         $HwRefusePerSite & ")"

# ---- liveness, as THREE outcomes ------------------------------------------

const HwLiveDead = 0'i32
const HwLiveYes = 1'i32
const HwLiveUnknown = -1'i32

var gHwLiveUnknownSaid = false

proc hwLiveVerdict(obj: Il2CppPtr): int32 =
  ## `UnityEngine.Object::op_Implicit` -- Unity's own destroyed-object test.
  ##
  ## THREE OUTCOMES, NEVER TWO. `nuAlive` collapses "this object is destroyed"
  ## and "I could not run the test" into the same `false`, and those must not
  ## be the same answer here: treating an unbound target as "dead" would drop
  ## every registered receiver and silently switch the caller off. "I could
  ## not look" is not a fail (CLAUDE.md 9b).
  ##
  ## `cNuFn` rather than `nuFn` on purpose: `nuFn` logs a refusal line every
  ## call, and this runs on a poll.
  let fn = cNuFn(NuTObjAlive)
  if fn == nil:
    if not gHwLiveUnknownSaid:
      gHwLiveUnknownSaid = true
      warn "hostWrite: UnityEngine.Object::op_Implicit did not bind, so the " &
           "DESTROYED-object test is unavailable this session. Receivers are " &
           "still klass-verified, but a destroyed object whose memory has " &
           "NOT yet been recycled will pass. Saying so rather than reporting " &
           "every receiver dead, which would disable the callers."
    return HwLiveUnknown
  if not nuOk(obj, 0x10'i32): return HwLiveDead
  if cNuCallBS1(fn, obj) != 0'i32: HwLiveYes else: HwLiveDead

# ---- what callers use -----------------------------------------------------

proc hostRecvOk*(site: string; recv, wantKlass: Il2CppPtr;
                 requireLive: bool = true): bool =
  ## THE GATE FOR A RECEIVER WRITTEN BY CALLING A GAME SETTER.
  ##
  ## This is the shape almost every host write actually has: we do not store
  ## into managed memory, we call `TMP_Text::set_text` / `SetLabelText` /
  ## `set_alpha` / `Toggle::Set` and let the game's own code do the storing.
  ## That means the OFFSET is chosen by the callee and cannot be bounded here
  ## -- so the receiver's TYPE is the whole of the protection, and it was
  ## missing everywhere.
  ##
  ## `requireLive` adds Unity's own destroyed-object test. Leave it on for any
  ## pointer that was captured on a screen that can close.
  result = false
  if wantKlass == nil:
    hwSay(site, recv, nil, nil, 0'i32, "-", false,
          "no klass was recorded when this receiver was captured, so there " &
          "is nothing to verify it against; an unrecorded expectation is a " &
          "refusal, not a waiver")
    return
  let got = nuKlassOf(recv)
  if cHwRecvKlassOk(recv, wantKlass) == 0'i32:
    hwSay(site, recv, wantKlass, got, 0'i32, "-", false,
          "the receiver's Il2CppClass* is NOT the one recorded at capture -- " &
          "this pointer now refers to a DIFFERENT type, which is what a " &
          "stale pointer into recycled GC memory looks like")
    return
  if requireLive and hwLiveVerdict(recv) == HwLiveDead:
    hwSay(site, recv, wantKlass, got, 0'i32, "-", false,
          "Unity's own Object::op_Implicit says this object has been " &
          "DESTROYED; its managed shell still reads back perfectly, which " &
          "is why every readability guard passed it")
    return
  hwSay(site, recv, wantKlass, got, 0'i32, "(setter call)", true, "")
  true

proc hostWriteI32*(site: string; recv, wantKlass: Il2CppPtr; off: int32;
                   instSize: uint32; v: int32): bool =
  ## A raw store. Refuses unless klass matches AND off+4 is inside instSize.
  let got = nuKlassOf(recv)
  if cHwStoreI32(recv, wantKlass, off, instSize, v) == 0'i32:
    hwSay(site, recv, wantKlass, got, off, $v, false,
          "the gate refused (klass mismatch, offset outside the instance " &
          "size, unknown instance size, or the span is not writable)")
    return false
  hwSay(site, recv, wantKlass, got, off, $v, true, "")
  true

proc hostWriteU8*(site: string; recv, wantKlass: Il2CppPtr; off: int32;
                  instSize: uint32; v: uint8): bool =
  let got = nuKlassOf(recv)
  if cHwStoreU8(recv, wantKlass, off, instSize, v) == 0'i32:
    hwSay(site, recv, wantKlass, got, off, $v, false, "the gate refused")
    return false
  hwSay(site, recv, wantKlass, got, off, $v, true, "")
  true

proc hostWriteF32*(site: string; recv, wantKlass: Il2CppPtr; off: int32;
                   instSize: uint32; v: float32): bool =
  let got = nuKlassOf(recv)
  if cHwStoreF32(recv, wantKlass, off, instSize, v) == 0'i32:
    hwSay(site, recv, wantKlass, got, off, nuF(v), false, "the gate refused")
    return false
  hwSay(site, recv, wantKlass, got, off, nuF(v), true, "")
  true

proc hostWritePtr*(site: string; recv, wantKlass: Il2CppPtr; off: int32;
                   instSize: uint32; v: Il2CppPtr): bool =
  let got = nuKlassOf(recv)
  if cHwStorePtr(recv, wantKlass, off, instSize, v) == 0'i32:
    hwSay(site, recv, wantKlass, got, off, hexOf(cast[uint64](v)), false,
          "the gate refused")
    return false
  hwSay(site, recv, wantKlass, got, off, hexOf(cast[uint64](v)), true, "")
  true

proc hostWriteSummary*(): string =
  ## For the run summary. Refusals are the interesting number: a non-zero
  ## klass-refusal count is a stale receiver that WOULD have corrupted memory.
  "hostWrite: allowed=" & $cHwAllowed() & " refused=" & $cHwRefused() &
  " (klass=" & $cHwRefusedKlass() & " bound=" & $cHwRefusedSize() &
  " mem=" & $cHwRefusedMem() & ")"
