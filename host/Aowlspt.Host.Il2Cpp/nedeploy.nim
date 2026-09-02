# nedeploy.nim -- THE DEPLOY-ORDER BREADCRUMB. A MEASUREMENT, NOT A FIX.
#
# ## The question this exists to answer, and why it cannot be answered offline
#
# `raidphase` latches DEPLOYED on `EFT.GameWorld::OnGameStarted` (S6, reached
# through its two `AfterGameStarted` subscribers -- see abi/aowlspt_raidstart.h).
# natesp draws its ESP boxes as soon as that latch is set. The user reports the
# boxes appearing BEFORE the raid is really under way, which is consistent with
# `OnGameStarted` firing when the deploy countdown BEGINS rather than when it
# ENDS and the player is released.
#
# That is a HYPOTHESIS. Nothing in the metadata can settle it: an RVA, a
# signature and a name say what a method IS, never WHEN it runs relative to
# another method. Six source-reasoning attempts at one bug all failed on this
# project; the empirical ones solved it. So this module measures the order and
# changes NOTHING about the gate.
#
# ## What is bound, and what each firing actually means
#
# All four rows were resolved offline on build 1.1.0.1.46777 with
# `il2cpp_resolve.py typemethods EFT.LocalGame` and `typemethods
# '<ShowCountdown>d__16'`, and EVERY one was separately checked with
# `il2cpp_resolve.py shared <RVA>`, which answered `UNIQUE owners=1` for all
# four. A row whose verdict was `shared` or `unknown` is not here -- `unknown`
# is a refusal, not a pass. No other feature in this host binds any of these
# four RVAs (grepped for each; loadperf's 33-row table, the only other
# raid-load table, holds TarkovApplication and ClientMetricsEvents targets and
# none of these).
#
#   EFT.LocalGame::SessionRun      0xAD0E80  UNIQUE  the session coroutine
#   EFT.LocalGame::ShowCountdown   0xAD1020  UNIQUE  the countdown coroutine
#   <ShowCountdown>d__16::MoveNext 0xAD5400  UNIQUE  ONE STEP of the countdown
#   EFT.LocalGame::Spawn           0xAD1160  UNIQUE  the spawn call itself
#
# **READ THIS BEFORE READING THE NUMBERS.** `SessionRun` and `ShowCountdown`
# return `IEnumerator`. Their compiled bodies are the coroutine FACTORIES: they
# allocate the state machine and return immediately. So their firing means the
# countdown was CREATED, NOT that it finished, and a reading that treats them
# as "the countdown ended" is wrong. The state machine's `MoveNext` is where
# the waiting actually happens, which is why it is bound too: its FIRST fire is
# the countdown's first step and its LAST fire is the step it completed on.
# `Spawn()` is an ordinary method and fires when it really runs.
#
# ## What the measurement can conclude, stated in advance
#
#   * `Spawn` (or the LAST `MoveNext`) after `OnGameStarted` and after natesp's
#     first draw -> the current gate IS early, and these rows name the later
#     signal it should use.
#   * `Spawn` and the last `MoveNext` BEFORE `OnGameStarted` -> the hypothesis
#     is WRONG: `OnGameStarted` is already the late signal and the early boxes
#     have another cause. This outcome is why the probe is worth building -- it
#     can falsify what we currently believe.
#   * nothing fires -> INCONCLUSIVE. Reported as "these four did not fire in
#     this raid", never as "the order is fine".
#
# ## Safety
#
# READ-ONLY, and not as a figure of speech: each handler compares a slot index
# against a four-entry array, stores a `cNowMs()` and increments two counters.
# It reads NO argument, dereferences NO game pointer and writes NO game memory,
# so there is nothing in it that CAN fault -- which is exactly why it opens no
# `aowl_p_p_seh` of its own. The guard is not re-entrant, these bodies run on
# whatever thread the patched method runs on, and a guard that protects nothing
# while disarming an outer one is a hazard, not a precaution. This is the same
# reasoning `loadperf.nim` records for the same shape.
#
# Every row is a POSTFIX drain, so the original always runs and returns exactly
# what it returned before. Prologues are verified against the STARTUP SNAPSHOT
# (`aowl_pro_verify`), never against live memory, so a target another feature
# patched first still verifies instead of self-rejecting on our own trampoline.
# Flag `natespDeployProbe`, DEFAULT OFF; with it off nothing binds and the
# dispatch arm returns false on one integer compare.

const NeDpRowCount = 4

{.emit: """
/* nedeploy's target table. See the Nim header above for provenance, for the
 * sharedness check on every row, and -- most importantly -- for what a firing
 * of a coroutine FACTORY does and does not mean.
 *
 * The 16 signature bytes are the ORIGINAL prologue read out of
 * GameAssembly.dll on disk (tools/il2cpp_resolve.py bytes <RVA>). They are
 * compared against the STARTUP SNAPSHOT, not against live memory. */
typedef struct AowlNdpTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
} AowlNdpTarget;

static const AowlNdpTarget aowl_ndp_targets[] = {
    /* 0 -- the session coroutine FACTORY. Fires when the coroutine object is
     * created, which is EARLY. Bound as the ordering floor, not as a signal. */
    { "EFT.LocalGame::SessionRun", 0xAD0E80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x57,0x48,0x83,0xEC,0x20,0x80,0x3D,0x00,0x88,0x5E,0x06 }, 16 },
    /* 1 -- the countdown coroutine FACTORY. Same caveat: creation, not end. */
    { "EFT.LocalGame::ShowCountdown", 0xAD1020u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x66,0x86,0x5E,0x06,0x00,0x48,0x8B,0xD9 }, 16 },
    /* 2 -- ONE STEP of the countdown state machine. This is the row that can
     * say when the countdown ENDED: its LAST fire is that step. */
    { "<ShowCountdown>d__16::MoveNext", 0xAD5400u,
      { 0x40,0x56,0x41,0x56,0x48,0x83,0xEC,0x38,0x80,0x3D,0x97,0x42,0x5E,0x06,0x00,0x48 }, 16 },
    /* 3 -- the spawn call itself. An ordinary method: it fires when it runs. */
    { "EFT.LocalGame::Spawn", 0xAD1160u,
      { 0x40,0x53,0x48,0x83,0xEC,0x20,0x80,0x3D,0x28,0x85,0x5E,0x06,0x00,0x48,0x8B,0xD9 }, 16 },
};

#define AOWL_NDP_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_ndp_targets) / sizeof(aowl_ndp_targets[0])))

static int32_t aowl_ndp_verified = 0;
static int32_t aowl_ndp_rejected = 0;

static int32_t aowl_ndp_target_count(void) { return AOWL_NDP_TARGET_COUNT; }

static const char* aowl_ndp_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_NDP_TARGET_COUNT) return "";
    return aowl_ndp_targets[i].name;
}

static uint32_t aowl_ndp_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_NDP_TARGET_COUNT) return 0u;
    return aowl_ndp_targets[i].rva;
}

/* Prime every row's ORIGINAL prologue into the startup snapshot before this
 * host patches anything. Called from `aowl_pro_prime_all`, which forward-
 * declares it: four rows of a 512-row table, unconditional, because the whole
 * point of the eager pass is not to depend on "nothing else patches that". */
static void aowl_ndp_prime_all(void) {
    int32_t i;
    for (i = 0; i < AOWL_NDP_TARGET_COUNT; i++)
        aowl_pro_prime(aowl_ndp_targets[i].rva);
}

/* Resolve one row to a live code pointer, or NULL. Committed executable memory
 * AND a startup-snapshot prologue match are both required; a mismatch returns
 * NULL, so a different game build gets a MISSED BIND and never a corrupted
 * game. */
static void* aowl_ndp_target_at(int32_t i) {
    HMODULE ga;
    const AowlNdpTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_NDP_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;

    t = &aowl_ndp_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return NULL;
    if (!aowl_pro_verify(t->rva, t->sig, t->siglen)) { aowl_ndp_rejected++; return NULL; }

    aowl_ndp_verified++;
    return (void*)p;
}

static int32_t aowl_ndp_rejected_count(void) { return aowl_ndp_rejected; }
""".}

proc cNdpTargetCount(): int32 {.importc: "aowl_ndp_target_count", nodecl.}
proc cNdpTargetName(i: int32): Il2CppPtr {.importc: "aowl_ndp_target_name", nodecl.}
proc cNdpTargetRva(i: int32): uint32 {.importc: "aowl_ndp_target_rva", nodecl.}
proc cNdpTargetAt(i: int32): Il2CppPtr {.importc: "aowl_ndp_target_at", nodecl.}
proc cNdpRejected(): int32 {.importc: "aowl_ndp_rejected_count", nodecl.}

var gNdpOn* = false            ## the `natespDeployProbe` flag; DEFAULT OFF
var gNdpBound = 0
var gNdpArming = -1
  ## Which row `attachDrain` is currently binding. `attachDrain` knows the KIND
  ## but not the ROW, so the row is parked here around the call -- the same
  ## shape `uihNoteSlot` and `lpNoteSlot` use.
var gNdpSlotOfRow: array[NeDpRowCount, int32] = [-1'i32, -1'i32, -1'i32, -1'i32]
var gNdpFirstMs: array[NeDpRowCount, uint64] = [0'u64, 0'u64, 0'u64, 0'u64]
var gNdpLastMs: array[NeDpRowCount, uint64] = [0'u64, 0'u64, 0'u64, 0'u64]
var gNdpHits: array[NeDpRowCount, int64] = [0'i64, 0'i64, 0'i64, 0'i64]
var gNdpAnnounced: array[NeDpRowCount, bool] = [false, false, false, false]
var gNdpOrder: array[NeDpRowCount, int32] = [-1'i32, -1'i32, -1'i32, -1'i32]
  ## The ORDER INDEX of each row's first fire -- 0 for whichever fired first.
  ## Recorded as a number rather than left to be inferred from the timestamps,
  ## because two rows can share a millisecond and a reader comparing equal
  ## timestamps would have to guess.
var gNdpOrderNext = 0'i32
var gNdpPending = false        ## a first-fire line is waiting to be printed
var gNdpNotBound = ""

proc ndpNoteSlot*(claimed: int32) =
  ## Called from `attachDrain`'s kind chain with the slot it just claimed.
  if gNdpArming >= 0 and gNdpArming < NeDpRowCount:
    gNdpSlotOfRow[gNdpArming] = claimed

proc ndpRowName(i: int): string =
  if i < 0 or i >= NeDpRowCount: "<out of range>"
  else: readCString(cNdpTargetName(int32(i)))

proc ndpSlotFired*(slot: int32): bool =
  ## Dispatched from `patchReturned` by slot identity, on whatever thread the
  ## patched method runs on. One array compare, one timestamp, two counters --
  ## no register is read and no game pointer is dereferenced, so nothing here
  ## can fault and it opens no SEH guard (see the header).
  ##
  ## Returns true when the slot was one of ours, so the caller can return at
  ## once. It NEVER suppresses the original: every row is a postfix drain.
  ##
  ## The early-out matters: `patchReturned` fires for other features' postfix
  ## slots as well, several of them per frame, so with the flag off this must
  ## not scan at all.
  if gNdpBound == 0: return false
  var i = 0
  while i < NeDpRowCount:
    if gNdpSlotOfRow[i] == slot:
      let now = cNowMs()
      if gNdpHits[i] == 0'i64:
        gNdpFirstMs[i] = now
        gNdpOrder[i] = gNdpOrderNext
        gNdpOrderNext = gNdpOrderNext + 1'i32
        gNdpPending = true
      gNdpLastMs[i] = now
      gNdpHits[i] = gNdpHits[i] + 1'i64
      return true
    inc i
  false

proc ndpDrainAnnounce*() =
  ## Emit the ONE line each row gets on its first fire. Called from natesp's
  ## drain tick, on the Unity main thread, so no logging happens inside the
  ## patched method itself.
  if not gNdpPending: return
  gNdpPending = false
  var i = 0
  while i < NeDpRowCount:
    if gNdpHits[i] > 0'i64 and not gNdpAnnounced[i]:
      gNdpAnnounced[i] = true
      okLog "natesp DEPLOY PROBE: order=" & $gNdpOrder[i] & " t=" &
            $gNdpFirstMs[i] & "ms  " & ndpRowName(i) &
            " fired for the FIRST time this raid. " &
            (if i == 0 or i == 1:
               "NOTE: this is the coroutine FACTORY -- the state machine was " &
               "CREATED here. It does NOT mean the countdown finished."
             elif i == 2:
               "This is ONE STEP of the countdown state machine; the LAST " &
               "fire is the step it completed on, not this one."
             else:
               "This is an ordinary method body, so it fired when it ran.")
    inc i

proc ndpOrderLine*(): string =
  ## The ordering, for natesp's deploy ledger. Reports what fired, in what
  ## order, with the count -- and says plainly when nothing fired, because "the
  ## probe saw nothing" is INCONCLUSIVE and must never read as "the order is
  ## fine".
  if not gNdpOn:
    return "deploy probe OFF (`natespDeployProbe`), so the ordering was NOT " &
           "measured -- INCONCLUSIVE, not a pass"
  if gNdpBound == 0:
    return "deploy probe ARMED BUT BOUND NOTHING" &
           (if gNdpNotBound.len > 0: " (" & gNdpNotBound & ")" else: "") &
           " -- nothing was measured"
  result = "deploy probe (" & $gNdpBound & "/" & $NeDpRowCount & " bound):"
  var any = false
  var i = 0
  while i < NeDpRowCount:
    if gNdpHits[i] > 0'i64:
      any = true
      result = result & " [order=" & $gNdpOrder[i] & " " & ndpRowName(i) &
               " first=" & $gNdpFirstMs[i] & "ms last=" & $gNdpLastMs[i] &
               "ms hits=" & $gNdpHits[i] & "]"
    else:
      result = result & " [" & ndpRowName(i) & " NEVER FIRED]"
    inc i
  if not any:
    result = result & " -- NOT ONE row fired in this raid. That is " &
             "INCONCLUSIVE about the deploy order; it is not evidence that " &
             "the current gate is right."

proc ndpReset*() =
  ## Per raid. A ledger carrying the previous raid's order would be a number
  ## that looks measured and is not.
  var i = 0
  while i < NeDpRowCount:
    gNdpFirstMs[i] = 0'u64
    gNdpLastMs[i] = 0'u64
    gNdpHits[i] = 0'i64
    gNdpAnnounced[i] = false
    gNdpOrder[i] = -1'i32
    inc i
  gNdpOrderNext = 0'i32
  gNdpPending = false

proc bindNeDeployProbe*(verbose: bool): bool =
  ## Bind the four read-only POSTFIX drains. Flag-gated, default OFF. Every row
  ## is attempted; a row that does not byte-verify against the startup snapshot
  ## is REFUSED ALOUD and the others still bind, because a partial ordering is
  ## still evidence while a silent partial bind is not.
  if not gNdpOn: return false
  if gNdpBound > 0: return true
  if int(cNdpTargetCount()) != NeDpRowCount:
    warn "natesp deploy probe: the C table has " & $int(cNdpTargetCount()) &
         " row(s) but the Nim side names " & $NeDpRowCount & ". REFUSING to " &
         "bind rather than index one table by the other's count."
    return false
  var i = 0
  while i < NeDpRowCount:
    let spec = ndpRowName(i)
    let fn = cNdpTargetAt(int32(i))
    if fn == nil:
      if gNdpNotBound.len > 0: gNdpNotBound.add ", "
      gNdpNotBound.add spec
      warn "natesp deploy probe: " & spec & " (rva " &
           $cNdpTargetRva(int32(i)) & ") did NOT verify against the STARTUP " &
           "PROLOGUE SNAPSHOT on this build, so it is NOT bound. The " &
           "ordering will be missing this row, and the ledger says so rather " &
           "than reporting a partial order as a whole one. " &
           $int(cNdpRejected()) & " row(s) rejected so far."
    else:
      gNdpArming = i
      let okBind = attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                               29'i32)
      gNdpArming = -1
      if okBind:
        inc gNdpBound
      else:
        if gNdpNotBound.len > 0: gNdpNotBound.add ", "
        gNdpNotBound.add spec & " (attach refused)"
    inc i
  if gNdpBound == 0:
    warn "natesp deploy probe: ARMED BUT BOUND NOTHING (" & gNdpNotBound &
         "). Nothing will be measured and the ledger reports INCONCLUSIVE."
    return false
  okLog "natesp deploy probe: " & $gNdpBound & "/" & $NeDpRowCount &
        " read-only POSTFIX drains bound (EFT.LocalGame SessionRun / " &
        "ShowCountdown / <ShowCountdown>d__16::MoveNext / Spawn -- all " &
        "UNIQUE, all verified against the startup prologue snapshot). It " &
        "MEASURES the deploy order and changes NO gate. Two of the four are " &
        "coroutine FACTORIES: their firing means the state machine was " &
        "created, NOT that the countdown ended."
  true

proc ndpRowFirstMs*(i: int): uint64 =
  ## `cNowMs()` of row `i`'s FIRST fire this raid, or 0 for "never fired".
  ## Zero is an ANSWER here, not a missing value, and every caller must treat
  ## it as "not measured" rather than as an early timestamp.
  if i < 0 or i >= NeDpRowCount: 0'u64
  else: gNdpFirstMs[i]

proc ndpRowLastMs*(i: int): uint64 =
  ## `cNowMs()` of row `i`'s LAST fire. For row 2 (`MoveNext`) this is the step
  ## the countdown completed on -- the closest thing to "the countdown ended"
  ## that this build exposes.
  if i < 0 or i >= NeDpRowCount: 0'u64
  else: gNdpLastMs[i]

proc ndpBoundCount*(): int = gNdpBound
