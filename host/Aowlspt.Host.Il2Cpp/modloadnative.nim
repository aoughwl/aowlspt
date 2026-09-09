# modloadnative.nim -- FEATURE F1 of docs/BOOT-FLOW-MAP.md: the mod load as a
# NATIVE STEP OF THE GAME'S OWN LOADING FLOW, driving the game's OWN caption
# instead of a from-scratch overlay beside it. `include`d into `aowlhost.nim`
# BEFORE `modload.nim`, because modload calls into this file and nimony
# forward-resolves procs across an include boundary but not vars or consts.
#
# Flag `modLoadNative`, DEFAULT OFF. With it off nothing is detoured, nothing
# is written, and every entry point below returns on one boolean compare.
#
# ===========================================================================
# WHAT THIS DOES, AND -- FIRST -- WHAT IT DELIBERATELY DOES NOT
# ===========================================================================
#
# The brief for F1 asks for a native step that WAITS, bounded, on the Unity
# main thread while the ops thread builds the mods. **THAT WAIT IS NOT
# IMPLEMENTED HERE, AND IT IS NOT AN OVERSIGHT.** Three measured facts make
# every shape of it either impossible or unsafe on this build:
#
#   1. We cannot inject managed code, so we cannot hand the game a `Task` that
#      completes when we say so and we cannot make any `await` in the boot's
#      async chain wait for us (BOOT-FLOW-MAP sec.3.1).
#   2. Spinning inside a detour on the Unity main thread freezes rendering and
#      the loading animation and makes Windows mark the window Not Responding
#      -- indistinguishable from the hang this whole screen exists to prevent
#      (sec.2, and it is also rule 7's spirit and rule 4's letter).
#   3. The only remaining mechanism is "delay the trigger", and the trigger --
#      whatever invokes `RunInitialLobbyFlow @0x97b550` -- is NOT IDENTIFIED.
#      MEASURED: 0 direct callers, 0 rip-relative references (sec.1.6). The map
#      names this Q1 and calls it "the single blocking unknown for F1".
#
# So this file ships the two halves that ARE derivable, and the instrument that
# settles Q1 so the third half can be built next:
#
#   A. THE MEASUREMENT (Q1 and Q2 at once). Read-only postfix drains on
#      `EFT.MenuLoadProfiler::StartFlow @0x9E2E80` and `::Begin @0x9E3310`,
#      logging the stage name and the THREAD ID of every stage the game itself
#      declares. That is verdict (1) of the brief, and it is the exact live
#      read Q1 and Q2 ask for.
#   B. THE CAPTION. The game's own profile-loading caption, driven with our
#      per-mod progress text, reached by WALKING FROM A VERIFIED LIVE OBJECT --
#      the `ProfileLoadingScreen` receiver the game itself hands us in RCX --
#      never from an offset off a pointer that can read null. That is verdict
#      (2), and it is what lets `modload.nim` stop drawing its own three-line
#      overlay on this path.
#
# THE STAGE NAME IS IN **RCX**, NOT RDX. The brief says RDX; that is wrong and
# would have logged the MethodInfo*. MEASURED, `il2cpp_resolve.py typemethods
# EFT.MenuLoadProfiler`: every member including `Begin(string name)` is
# `PUBLIC|STATIC|HIDEBYSIG`. A static's first argument is RCX and the trailing
# `MethodInfo*` is RDX. docs/BOOT-FLOW-MAP.md sec.3.5 says RCX and is right.
#
# ===========================================================================
# THE FOUR TARGETS -- AND THE FIFTH, WHICH IS REFUSED
# ===========================================================================
#
# Every row was re-checked on build 1.1.0.1.46777 with
# `il2cpp_resolve.py shared <RVA>` -- ALL FOUR answer `UNIQUE owners=1`; a row
# that had answered `shared` or `unknown` would not be here, because `unknown`
# is a refusal and not a pass. The 16 signature bytes are the ORIGINAL prologue
# read off GameAssembly.dll on disk with `il2cpp_resolve.py bytes <RVA>`.
#
#   0  EFT.MenuLoadProfiler::StartFlow(string)        0x9E2E80  2 slots
#   1  EFT.MenuLoadProfiler::Begin(string)            0x9E3310  2 slots
#   2  EFT.UI.ProfileLoadingScreen::Show(bool)        0x157AA40 3 slots
#   3  EFT.UI.ProfileLoadingScreen::SetLivingStatus   0x157ABE0 3 slots
#
# Rows 0/1 are static, so their slot count is (1 argument + MethodInfo*) = 2.
# Rows 2/3 are instance: (this + 1 argument + MethodInfo*) = 3. All are <= 4,
# so all four are legal POSTFIX drains and `attachDrain`'s slot gate is given
# the real number rather than left to derive one.
#
# **NO ROW IS BOUND BY ANY OTHER FEATURE.** Grepped for each of the four RVAs
# across `host/**.nim` and `abi/**.h`: the only hits are this file. That
# matters because a second detour on one function overwrites the first's
# trampoline and kills the first feature silently. If a future feature wants
# one of these, it must RIDE this drain, not bind its own.
#
# THE FIFTH TARGET IS REFUSED, AND THIS IS THE POINT.
# `EFT.TarkovApplication::TryCreateInRaidCharacterSelection @0x97BBF0` is the
# hook site the F1 brief names, and it is NOT bound here, because
# **`modeskip.nim` ALREADY BINDS IT** -- a PREFIX, kind 34,
# `bindModeSkipNative`, target `AOWL_MSK_TRYCREATE_RVA 0x97bbf0` in
# `abi/aowlspt_modeskip.h`. A second detour on one function overwrites the
# first's trampoline and kills the first feature SILENTLY (CLAUDE.md sec.5), so
# binding it here would have disabled the mode-screen skip without one line of
# log saying so. The rule is: RIDE THE EXISTING DETOUR AS A DRAIN. When this
# file needs that ordering fact, the place to add it is modeskip's own handler,
# not a second bind -- and it is deliberately NOT added today, because F1's
# hold cannot be built on it anyway (see above).
#
# ===========================================================================
# WHY THE PROLOGUE SNAPSHOT IS PRIMED LAZILY HERE
# ===========================================================================
#
# `aowl_pro_verify` compares against the STARTUP SNAPSHOT, never against live
# memory, so a target another feature patched first still verifies instead of
# self-rejecting on our own trampoline. Rows are primed EAGERLY from
# `aowl_pro_prime_all` for contended tables; these four are primed LAZILY, on
# our own first verify, which `abi/aowlspt_prologue.h` documents as correct
# precisely when the first verify necessarily precedes the first patch. It does
# here: nothing else in this host touches these four RVAs (grepped, above), and
# our verify runs before our bind. If a feature is ever added that patches one
# of them, ADD THESE FOUR TO `aowl_pro_prime_all` -- do not rely on this note.
#
# ===========================================================================
# SAFETY -- the eight rules, for THIS file
# ===========================================================================
#
# 1. 16-byte prologue byte-verify against the startup snapshot before every
#    bind, in `aowl_mln_target_at`. A mismatch returns NULL, the row is not
#    bound, and the refusal names the row.
# 2. Every pointer hop `aowl_is_readable`/VirtualQuery'd: the screen receiver
#    (`duOk` + `iUnityAlive`), `_statusField@0xb0` before it is read, and the
#    TMP before it is written. `screen->_statusField->m_text` is three checks.
# 3. ONE `aowl_p_p_seh` per body -- **THIS FILE OPENS NONE**. The detour
#    handlers run inside the game's own call and touch no game memory at all
#    (see below); the caption driver runs from `modLoadTick`, which already
#    rides the shared per-frame drain INSIDE that drain's guard, and
#    `aowl_p_p_seh` is not re-entrant, so a guard here would DISARM the outer
#    one rather than add protection.
# 4. Capped iteration: the only loops are over `MlnRowCount` (4) and over the
#    stage ring (`AOWL_MLN_STAGE_MAX`, 64), both compile-time constants.
# 5. Flag-gated, DEFAULT OFF (`modLoadNative`).
# 6. Self-disable after `MlnMaxRefusals` consecutive caption refusals, and the
#    write count is capped at `MlnMaxWrites` regardless.
# 7. No per-frame managed allocation: the caption is re-applied only when the
#    text CHANGED or `MlnReapplyMs` has elapsed, and `il2cpp_string_new` is
#    reached only on those writes -- never on an idle frame.
# 8. Never blind-write. The caption is not written until the game's OWN caption
#    has been READ BACK non-empty from that same TMP at least once. That read
#    is what proves the pointer is a TMP_Text at all, and it is also the live
#    answer to the map's Q7 (what `PROFILE_LOADING_TEXT` decodes to), which the
#    encrypted metadata cannot give.
#
# THE DETOUR HANDLERS ALLOCATE NOTHING IN NIM. A Nim `string` built on the game
# thread and released on another is a cross-thread free -- defect #5 of
# docs/INTERACTION-LAYER-MAP.md sec.0, an ARC global assigned from two threads.
# So the stage name is decoded into a STATIC C BUFFER by `aowl_mln_note_stage`,
# inside the detour, and only ever read back as a `cstring` on the drain
# thread. Nothing in the handler path touches the Nim heap.

const
  MlnRowCount = 4
  MlnRowStartFlow = 0
  MlnRowBegin = 1
  MlnRowScreenShow = 2
  MlnRowLivingStatus = 3

  MlnStatusFieldOff = 0xb0'i32
    ## `EFT.UI.ProfileLoadingScreen._statusField`, a `CustomTextMeshProUGUI`.
    ## MEASURED `il2cpp_resolve.py fields EFT.UI.ProfileLoadingScreen`. NOT
    ## guessed, and never read without `duOk` on the screen first.
  MlnTmpProbeSize = 0x120'i32
    ## How far the `_statusField` pointer must be readable before it is treated
    ## as a TMP_Text at all: `m_text@0xe0` and `m_fontAsset@0x100` are both
    ## inside this, and `nuGetText` reads through the real getter.
  MlnReapplyMs = 400'u64
    ## How often an UNCHANGED caption is re-applied. The game rewrites
    ## `_statusField` from its own side whenever `Show`/`SetLivingStatus` runs
    ## (BOOT-FLOW-MAP sec.1.11), and a `LocalizedText` may clobber it too, so a
    ## write that is never re-applied is a write that does not stick.
  MlnMaxWrites = 600
    ## Hard cap on caption writes for the whole session. Each is one
    ## `il2cpp_string_new` plus one setter call; 600 at 400ms is four minutes,
    ## which is `ModLoadDeferMaxMs`.
  MlnMaxRefusals = 8
    ## Consecutive caption refusals before this feature switches its caption
    ## half off for the session and SAYS SO (rule 6). The drains keep counting.
  MlnMaxStageLines = 64
    ## Stage lines written to the log before the drain goes quiet. The report
    ## still counts every stage; only the per-stage lines are capped.

{.emit: """
/* modloadnative's target table. Provenance, sharedness and the postfix slot
 * counts are in the Nim header above. The 16 signature bytes are the ORIGINAL
 * prologue from GameAssembly.dll on disk and are compared against the STARTUP
 * SNAPSHOT (aowl_pro_verify), never against live memory. */
typedef struct AowlMlnTarget {
    const char*         name;
    uint32_t            rva;
    const unsigned char sig[16];
    int32_t             siglen;
    int32_t             slots;
} AowlMlnTarget;

static const AowlMlnTarget aowl_mln_targets[] = {
    /* 0 -- the profiler's flow start. STATIC: RCX = the mark name. */
    { "EFT.MenuLoadProfiler::StartFlow", 0x9E2E80u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x40,0x48 }, 16, 2 },
    /* 1 -- one named stage. STATIC: RCX = the stage name. THE instrument for
     * Q1/Q2: the game's own boot-stage log, with our thread ids attached. */
    { "EFT.MenuLoadProfiler::Begin", 0x9E3310u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x81,0xEC,0x90,0x00 }, 16, 2 },
    /* 2 -- the profile loading screen is being shown. RCX = the live screen,
     * which is the ONLY verified-live route to `_statusField@0xb0`. */
    { "EFT.UI.ProfileLoadingScreen::Show", 0x157AA40u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x0F }, 16, 3 },
    /* 3 -- the game writing its OWN caption. RCX = the live screen. A POSTFIX
     * here fires AFTER the game's own `set_text`, which is exactly when a
     * re-apply of ours has to happen. Byte 15 (0x80) opens a rip-relative
     * `cmp byte [rip+d],0`; that is fine for a 16-byte COMPARE, and if the
     * detour engine has to steal it and cannot relocate it, the attach is
     * REFUSED loudly and this row simply does not bind. */
    { "EFT.UI.ProfileLoadingScreen::SetLivingStatus", 0x157ABE0u,
      { 0x48,0x89,0x5C,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xEC,0x20,0x80 }, 16, 3 },
};

#define AOWL_MLN_TARGET_COUNT \
    ((int32_t)(sizeof(aowl_mln_targets) / sizeof(aowl_mln_targets[0])))

#define AOWL_MLN_STAGE_MAX  64
#define AOWL_MLN_STAGE_CHARS 48

/* The stage ring. Written INSIDE the detour, on the game's thread, with no
 * heap of any kind -- see the Nim header on cross-thread frees. Read back on
 * the drain thread as a plain cstring. */
typedef struct AowlMlnStage {
    char     name[AOWL_MLN_STAGE_CHARS];
    uint32_t tid;
    uint64_t ms;
    int32_t  row;
    int32_t  decoded;   /* 1 = the string decoded; 0 = it did not, and SAYS so */
} AowlMlnStage;

static AowlMlnStage aowl_mln_stages[AOWL_MLN_STAGE_MAX];
static int32_t aowl_mln_stage_n     = 0;   /* stages RECORDED (capped)  */
static int32_t aowl_mln_stage_seen  = 0;   /* stages OBSERVED (uncapped) */
static int32_t aowl_mln_stage_undec = 0;   /* observed but not decodable  */
static int32_t aowl_mln_verified    = 0;
static int32_t aowl_mln_rejected    = 0;

static int32_t aowl_mln_target_count(void) { return AOWL_MLN_TARGET_COUNT; }

static const char* aowl_mln_target_name(int32_t i) {
    if (i < 0 || i >= AOWL_MLN_TARGET_COUNT) return "";
    return aowl_mln_targets[i].name;
}
static uint32_t aowl_mln_target_rva(int32_t i) {
    if (i < 0 || i >= AOWL_MLN_TARGET_COUNT) return 0u;
    return aowl_mln_targets[i].rva;
}
static int32_t aowl_mln_target_slots(int32_t i) {
    if (i < 0 || i >= AOWL_MLN_TARGET_COUNT) return -1;
    return aowl_mln_targets[i].slots;
}

/* Resolve one row to a live code pointer, or NULL. Committed EXECUTABLE memory
 * AND a startup-snapshot prologue match are both required; a mismatch returns
 * NULL, so a different game build gets a MISSED BIND and never a corrupted
 * game. Identical in shape to nedeploy's, deliberately. */
static void* aowl_mln_target_at(int32_t i) {
    HMODULE ga;
    const AowlMlnTarget* t;
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;

    if (i < 0 || i >= AOWL_MLN_TARGET_COUNT) return NULL;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) return NULL;

    t = &aowl_mln_targets[i];
    p = (unsigned char*)ga + t->rva;

    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) return NULL;
    if (mbi.State != MEM_COMMIT) return NULL;
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) return NULL;
    if (!aowl_pro_verify(t->rva, t->sig, t->siglen)) { aowl_mln_rejected++; return NULL; }

    aowl_mln_verified++;
    return (void*)p;
}

/* Record one stage, from inside the detour. `s` is a System.String* taken
 * straight out of RCX and is NEVER trusted: every read is aowl_is_readable'd
 * first, exactly as suiReadString does, and a slot that is not a String is
 * recorded as UNDECODED rather than skipped -- "I could not look" is not a
 * pass, and a stage the drain saw but could not name is still evidence that
 * the stage happened. */
static void aowl_mln_note_stage(void* s, int32_t row, uint32_t tid, uint64_t ms) {
    AowlMlnStage* e;
    int32_t n, i;
    unsigned char* p = (unsigned char*)s;

    aowl_mln_stage_seen++;
    if (aowl_mln_stage_n >= AOWL_MLN_STAGE_MAX) return;
    e = &aowl_mln_stages[aowl_mln_stage_n];
    e->name[0] = 0;
    e->tid = tid;
    e->ms  = ms;
    e->row = row;
    e->decoded = 0;

    if (p && aowl_is_readable(p, 0x14)) {
        n = *(int32_t*)(p + 0x10);
        if (n > 0 && n < AOWL_MLN_STAGE_CHARS &&
            aowl_is_readable(p + 0x14, n * 2)) {
            const unsigned short* w = (const unsigned short*)(p + 0x14);
            for (i = 0; i < n; i++) {
                unsigned short c = w[i];
                if (c == 0) break;
                e->name[i] = (c >= 0x20 && c <= 0x7E) ? (char)c : '?';
            }
            e->name[i] = 0;
            e->decoded = 1;
        }
    }
    if (!e->decoded) { aowl_mln_stage_undec++; }
    aowl_mln_stage_n++;
}

static int32_t     aowl_mln_stage_count(void)     { return aowl_mln_stage_n; }
static int32_t     aowl_mln_stage_seen_count(void){ return aowl_mln_stage_seen; }
static int32_t     aowl_mln_stage_undecoded(void) { return aowl_mln_stage_undec; }
static int32_t     aowl_mln_rejected_count(void)  { return aowl_mln_rejected; }
static const char* aowl_mln_stage_name(int32_t i) {
    if (i < 0 || i >= aowl_mln_stage_n) return "";
    return aowl_mln_stages[i].name;
}
static uint32_t aowl_mln_stage_tid(int32_t i) {
    if (i < 0 || i >= aowl_mln_stage_n) return 0u;
    return aowl_mln_stages[i].tid;
}
static uint64_t aowl_mln_stage_ms(int32_t i) {
    if (i < 0 || i >= aowl_mln_stage_n) return 0ull;
    return aowl_mln_stages[i].ms;
}
static int32_t aowl_mln_stage_row(int32_t i) {
    if (i < 0 || i >= aowl_mln_stage_n) return -1;
    return aowl_mln_stages[i].row;
}
static int32_t aowl_mln_stage_decoded(int32_t i) {
    if (i < 0 || i >= aowl_mln_stage_n) return 0;
    return aowl_mln_stages[i].decoded;
}
""".}

proc cMlnTargetCount(): int32 {.importc: "aowl_mln_target_count", nodecl.}
proc cMlnTargetName(i: int32): Il2CppPtr {.importc: "aowl_mln_target_name", nodecl.}
proc cMlnTargetRva(i: int32): uint32 {.importc: "aowl_mln_target_rva", nodecl.}
proc cMlnTargetSlots(i: int32): int32 {.importc: "aowl_mln_target_slots", nodecl.}
proc cMlnTargetAt(i: int32): Il2CppPtr {.importc: "aowl_mln_target_at", nodecl.}
proc cMlnRejected(): int32 {.importc: "aowl_mln_rejected_count", nodecl.}
proc cMlnNoteStage(s: Il2CppPtr; row: int32; tid: uint32; ms: uint64) {.
  importc: "aowl_mln_note_stage", nodecl.}
proc cMlnStageCount(): int32 {.importc: "aowl_mln_stage_count", nodecl.}
proc cMlnStageSeen(): int32 {.importc: "aowl_mln_stage_seen_count", nodecl.}
proc cMlnStageUndecoded(): int32 {.importc: "aowl_mln_stage_undecoded", nodecl.}
proc cMlnStageName(i: int32): Il2CppPtr {.importc: "aowl_mln_stage_name", nodecl.}
proc cMlnStageTid(i: int32): uint32 {.importc: "aowl_mln_stage_tid", nodecl.}
proc cMlnStageMs(i: int32): uint64 {.importc: "aowl_mln_stage_ms", nodecl.}
proc cMlnStageRow(i: int32): int32 {.importc: "aowl_mln_stage_row", nodecl.}
proc cMlnStageDecoded(i: int32): int32 {.importc: "aowl_mln_stage_decoded", nodecl.}

var gMlnOn* = false
  ## `modLoadNative`, DEFAULT OFF. Read in `aowlhost.nim`'s config block.
var gMlnBound = 0
var gMlnArming = -1
  ## Which row `attachDrain` is binding. It knows the KIND, not the ROW, so the
  ## row is parked here around the call -- the shape `uihNoteSlot`,
  ## `lpNoteSlot` and `ndpNoteSlot` all use.
var gMlnSlotOfRow: array[MlnRowCount, int32] = [-1'i32, -1'i32, -1'i32, -1'i32]
var gMlnHits: array[MlnRowCount, int64] = [0'i64, 0'i64, 0'i64, 0'i64]
var gMlnFirstMs: array[MlnRowCount, uint64] = [0'u64, 0'u64, 0'u64, 0'u64]
var gMlnNotBound = ""

## THE SCREEN. Captured from rows 2/3's RCX -- a receiver the game itself
## handed us -- and never from an offset that could read null.
var gMlnScreen: Il2CppPtr = nil
var gMlnScreenAtMs = 0'u64
var gMlnScreenTid = 0'u32
var gMlnScreenSaid = false

## THE CAPTION.
var gMlnTmp: Il2CppPtr = nil          ## `_statusField@0xb0`, once validated
var gMlnGameCaption = ""              ## what the GAME's own caption reads (Q7)
var gMlnGameCaptionSaid = false
var gMlnWant = ""                     ## the line we want on screen
var gMlnApplied = ""                  ## the line we last wrote
var gMlnLastWriteMs = 0'u64
var gMlnWrites = 0
var gMlnRefusals = 0                  ## CONSECUTIVE refusals; rule 6
var gMlnCaptionOff = false            ## the caption half self-disabled
var gMlnCaptionWhy = ""
var gMlnDrove = false                 ## at least one write LANDED (read back)
var gMlnReadbackDone = false
var gMlnReadbackPass = false
var gMlnReadbackWhy = ""
var gMlnFirstWriteMs = 0'u64
var gMlnStagesSaid = 0

## THE ORDERING LEDGER -- the brief's verdicts (3) and (4).
var gMlnReleaseMs = 0'u64             ## when the OPS thread performed the release
var gMlnReleaseTid = 0'u32
var gMlnCtorsAtRelease = -1           ## modeskip's controller .ctor count then
var gMlnSlotsAtRelease = -1           ## modeskip's ShowSlot count then
var gMlnVerdictSaid = false

proc mlnNoteSlot*(claimed: int32) =
  ## Called from `attachDrain`'s kind chain with the slot it just claimed.
  if gMlnArming >= 0 and gMlnArming < MlnRowCount:
    gMlnSlotOfRow[gMlnArming] = claimed

proc mlnRowName(i: int): string =
  if i < 0 or i >= MlnRowCount: "<out of range>"
  else: readCString(cMlnTargetName(int32(i)))

proc mlnSlotFired*(slot: int32; regs: Il2CppPtr): bool =
  ## Dispatched from `patchReturned` by SLOT IDENTITY, on whatever thread the
  ## patched method runs on, inside the game's own call.
  ##
  ## OPENS NO SEH GUARD, and that is a considered decision, not an omission.
  ## The only game memory reached from here is the stage-name String, and that
  ## goes through `aowl_mln_note_stage`, which `aowl_is_readable`s (a
  ## VirtualQuery, not a faulting dereference) before every byte it touches.
  ## The screen rows store a POINTER after `duOk` + `iUnityAlive` and
  ## dereference nothing. `aowl_p_p_seh` is not re-entrant and these bodies can
  ## run inside another guarded region, so a guard here could DISARM one that
  ## is protecting more than this.
  ##
  ## Returns true when the slot was ours so the caller can return at once. It
  ## NEVER suppresses the original: every row is a postfix drain and this
  ## always leaves the caller with what the original produced.
  if gMlnBound == 0: return false
  var i = 0
  while i < MlnRowCount:
    if gMlnSlotOfRow[i] == slot:
      let now = cNowMs()
      let tid = cThreadId()
      if gMlnHits[i] == 0'i64: gMlnFirstMs[i] = now
      gMlnHits[i] = gMlnHits[i] + 1'i64
      if i == MlnRowStartFlow or i == MlnRowBegin:
        # RCX, not RDX: these are STATIC (MEASURED, see the header), so the
        # declared argument is the first register and RDX is the MethodInfo*.
        cMlnNoteStage(cast[Il2CppPtr](cRegsInt(regs, 0'i32)),
                      int32(i), tid, now)
      elif i == MlnRowScreenShow or i == MlnRowLivingStatus:
        let self = cast[Il2CppPtr](cRegsInt(regs, 0'i32))
        if self != nil and duOk(self, MlnStatusFieldOff + 8'i32) and
           iUnityAlive(self):
          gMlnScreen = self
          if gMlnScreenAtMs == 0'u64:
            gMlnScreenAtMs = now
            gMlnScreenTid = tid
      return true
    inc i
  false

proc mlnStageDrain() =
  ## Print the stage lines this session has recorded but not yet said. Runs on
  ## the drain (Unity main) thread, never inside the patched method, so no
  ## logging happens in the game's own call. THE BRIEF'S VERDICT (1).
  let n = int(cMlnStageCount())
  while gMlnStagesSaid < n and gMlnStagesSaid < MlnMaxStageLines:
    let i = int32(gMlnStagesSaid)
    inc gMlnStagesSaid
    let row = int(cMlnStageRow(i))
    let tid = cMlnStageTid(i)
    okLog "modload native: STAGE " & $i & "  " &
          (if row == MlnRowStartFlow: "StartFlow" else: "Begin") &
          "  name=" &
          (if cMlnStageDecoded(i) != 0'i32:
             "\"" & readCString(cMlnStageName(i)) & "\""
           else:
             "<UNDECODED -- RCX was not a readable System.String; the stage " &
             "HAPPENED, its name is not claimed>") &
          "  thread=" & $int(tid) &
          (if int(tid) == int(gHostThreadId):
             " (the HOST OPS thread -- NOT Unity's)"
           elif int(tid) == int(cMqThread()):
             " (the Unity main thread, same as the per-frame drain)"
           else: " (neither the ops thread nor the drain owner)") &
          "  t=" & $cMlnStageMs(i) & "ms"

proc mlnStatusField(): Il2CppPtr =
  ## `screen -> _statusField@0xb0`, THREE checks, not one: the screen is a live
  ## Unity object, it is readable as far as the field, and the field's own
  ## pointer is readable far enough to be a TMP_Text. Returns nil and says
  ## nothing on any failed hop -- the caller decides what to log.
  result = nil
  let s = gMlnScreen
  if s == nil: return
  if not duOk(s, MlnStatusFieldOff + 8'i32): return
  if not iUnityAlive(s): return
  let tmp = cReadPtrAt(s, MlnStatusFieldOff)
  if tmp == nil: return
  if not duOk(tmp, MlnTmpProbeSize): return
  if not iUnityAlive(tmp): return
  result = tmp

proc mlnRefuse(why: string) =
  ## One consecutive-refusal step, with the message printed only when the
  ## reason CHANGES or the feature is about to switch itself off. A refusal
  ## every frame is noise; a refusal nobody prints is the failure mode this
  ## host least tolerates.
  inc gMlnRefusals
  if gMlnCaptionWhy != why:
    gMlnCaptionWhy = why
    info "modload native: caption NOT driven -- " & why
  if gMlnRefusals >= MlnMaxRefusals and not gMlnCaptionOff:
    gMlnCaptionOff = true
    warn "modload native: the CAPTION half has SELF-DISABLED after " &
         $gMlnRefusals & " consecutive refusals (" & why & "). The " &
         "read-only stage drains keep running and keep counting. " &
         "`modload.nim`'s own three-line overlay is the fallback and is " &
         "still gated on its own flag."

proc mlnCaptionSet*(line: string) =
  ## What `modload.nim` wants the game's caption to read. Called from the drain
  ## tick on the Unity main thread. Stores only; the write happens in
  ## `mlnDrive`, which owns the validation and the cadence.
  if not gMlnOn: return
  gMlnWant = line

proc mlnDrives*(): bool =
  ## TRUE only once a write has been READ BACK off the live TMP. This is what
  ## `modload.nim` suppresses its own overlay on, and it is deliberately a
  ## property of the FINISHED STATE (the tree renders our text) rather than of
  ## our own write having been issued -- CLAUDE.md 9b. Before the first
  ## verified write it is false, so the old overlay still runs and the player
  ## is never left with no progress at all.
  gMlnOn and gMlnDrove and not gMlnCaptionOff

proc mlnArmed*(): bool =
  ## True when the feature is on AND at least one row bound. A flag that is on
  ## while nothing bound must not read as "the native step is running".
  gMlnOn and gMlnBound > 0

proc mlnDrive*() =
  ## THE CAPTION DRIVER. Called once per `modLoadTick`, on the Unity main
  ## thread, INSIDE the shared drain's existing `aowl_p_p_seh` -- it opens
  ## none of its own (rule 3).
  ##
  ## Order matters and is the whole of rule 8: READ the game's own caption
  ## first, and only write if that read produced text. A pointer that hands
  ## back a real string through `TMP_Text::get_text` is a TMP_Text; a pointer
  ## that does not is refused, never written to.
  if not gMlnOn or gMlnCaptionOff: return
  mlnStageDrain()
  if gMlnWant.len == 0: return
  if gMlnWrites >= MlnMaxWrites:
    if not gMlnCaptionOff:
      gMlnCaptionOff = true
      warn "modload native: caption write cap (" & $MlnMaxWrites &
           ") reached; the caption half stops here. This is a bound, not a " &
           "fault -- " & $gMlnWrites & " writes landed."
    return

  let tmp = mlnStatusField()
  if tmp == nil:
    if gMlnScreen == nil:
      mlnRefuse("no ProfileLoadingScreen receiver yet. Rows 2/3 (" &
                mlnRowName(MlnRowScreenShow) & " / " &
                mlnRowName(MlnRowLivingStatus) & ") have fired " &
                $(gMlnHits[MlnRowScreenShow] + gMlnHits[MlnRowLivingStatus]) &
                " time(s). Until one fires there is NO verified live object " &
                "to walk from, and this refuses to reach the screen any " &
                "other way.")
    else:
      mlnRefuse("the ProfileLoadingScreen receiver is live but " &
                "_statusField@0xb0 does not read back as a TMP_Text " &
                "(null, unreadable to +0x" & hexOf(uint64(MlnTmpProbeSize)) &
                ", or a destroyed Unity object). NOTHING was written.")
    gMlnTmp = nil
    return
  gMlnTmp = tmp

  if gMlnGameCaption.len == 0:
    # THE PRECONDITION FOR EVERY WRITE, and the live answer to map Q7.
    let cur = nuGetText(tmp)
    if cur.len == 0:
      mlnRefuse("_statusField reads back EMPTY through TMP_Text::get_text. " &
                "That is either not a TMP_Text or a caption the game has not " &
                "filled yet, and this will not write into a pointer it has " &
                "not first read a string out of (rule 8: never blind-write).")
      return
    gMlnGameCaption = cur
    if not gMlnGameCaptionSaid:
      gMlnGameCaptionSaid = true
      okLog "modload native: the GAME'S OWN caption on this screen reads \"" &
            cur & "\" -- read back off _statusField@0xb0 through " &
            "TMP_Text::get_text. That is the live value of " &
            "ProfileLoadingScreen.PROFILE_LOADING_TEXT, which the encrypted " &
            "metadata cannot give (BOOT-FLOW-MAP Q7), and it is also the " &
            "proof that this pointer is a TMP_Text before anything is " &
            "written to it."

  let now = cNowMs()
  let changed = gMlnWant != gMlnApplied
  if not changed and now - gMlnLastWriteMs < MlnReapplyMs:
    return

  # THE WRITE. `nuSetText` calls the REAL setter (TMP_Text::set_text
  # @0x51BC1E0, byte-verified by nativeui's own table) and never stores m_text
  # raw. It is issued TWICE because `LocalizedText` and the game's own
  # `SetLivingStatus` both rewrite this field, and a write that is not
  # re-applied does not stick.
  if not nuSetText(tmp, gMlnWant):
    mlnRefuse("TMP_Text::set_text refused (nativeui is off, its target table " &
              "did not verify, or il2cpp_string_new returned nothing).")
    return
  discard nuSetText(tmp, gMlnWant)
  gMlnRefusals = 0
  gMlnCaptionWhy = ""
  gMlnApplied = gMlnWant
  gMlnLastWriteMs = now
  inc gMlnWrites
  if gMlnFirstWriteMs == 0'u64: gMlnFirstWriteMs = now

  # THE READBACK -- the brief's verdict (2), asserted ONCE against the
  # FINISHED STATE. It reads the property, not the field we wrote, and it is
  # allowed to FAIL: a caption that did not stick reports FAIL here rather
  # than being inferred to have worked from `set_text` returning.
  if not gMlnReadbackDone:
    gMlnReadbackDone = true
    let back = nuGetText(tmp)
    if back == gMlnWant:
      gMlnReadbackPass = true
      gMlnDrove = true
      gMlnReadbackWhy = "the live TMP reads back exactly what was written"
      okLog "modload native: CAPTION VERDICT **PASS** -- the game's own " &
            "profile-loading caption now reads \"" & back & "\", read back " &
            "off the live TMP through TMP_Text::get_text after the write. " &
            "The mod-load progress is now a line of the client's OWN loading " &
            "screen, not an overlay beside it. modload.nim's three-line " &
            "overlay stands down on this path."
    elif back.len == 0:
      gMlnReadbackWhy = "the readback was empty"
      warn "modload native: CAPTION VERDICT **INCONCLUSIVE** -- the write " &
           "was issued and TMP_Text::get_text then returned NOTHING. That is " &
           "not evidence the caption is ours and it is not evidence it is " &
           "not; the overlay is left running."
    else:
      gMlnReadbackWhy = "the live TMP reads \"" & back & "\""
      warn "modload native: CAPTION VERDICT **FAIL** -- we wrote \"" &
           gMlnWant & "\" and the live TMP reads \"" & back & "\". Something " &
           "clobbered it between the write and the read; the usual cause is " &
           "a LocalizedText on this node, which must be driven through " &
           "LocalizedText::SetLabelText @0x140FE70 as well. The overlay is " &
           "left running rather than leaving the player with neither."

proc mlnNoteRelease*(tid: uint32) =
  ## Called from `modLoadReleaseDrain` ON THE OPS THREAD, immediately after the
  ## deferred mods were released. Writes plain integers only -- no Nim string
  ## is assigned here, because this proc and `mlnDrive` run on different
  ## threads and an ARC global assigned from two threads is a cross-thread
  ## free (INTERACTION-LAYER-MAP sec.0 defect #5).
  if not gMlnOn: return
  if gMlnReleaseMs != 0'u64: return
  gMlnReleaseMs = cNowMs()
  gMlnReleaseTid = tid
  # THE CENSUS FOR VERDICT (4), snapshotted AT the release rather than read
  # later: "were any character-selection frames rendered before the mods were
  # released?" is a question about that instant.
  gMlnCtorsAtRelease = gModeSkipCtors
  gMlnSlotsAtRelease = gModeSkipSlotsSeen

proc mlnReport*(): seq[string] =
  ## Rows for the boot summary. States BOUND/unbound and the fire count per
  ## row separately; a row that bound and never fired is not the same as a row
  ## that never bound, and collapsing them would hide the case the prologue
  ## verify exists to catch.
  result = @[]
  if not gMlnOn:
    result.add("  modLoadNative OFF -- the native loading step was not armed, " &
               "so NOTHING here was measured (INCONCLUSIVE, not a pass)")
    return
  result.add("  modLoadNative: " & $gMlnBound & "/" & $MlnRowCount &
             " read-only POSTFIX drain(s) bound, " & $int(cMlnRejected()) &
             " row(s) refused by the startup prologue snapshot" &
             (if gMlnNotBound.len > 0: " (" & gMlnNotBound & ")" else: ""))
  var i = 0
  while i < MlnRowCount:
    result.add("    row " & $i & " " & mlnRowName(i) & " @0x" &
               hexOf(uint64(cMlnTargetRva(int32(i)))) & ": " &
               (if gMlnSlotOfRow[i] >= 0: "BOUND (slot " & $gMlnSlotOfRow[i] &
                  ", " & $int(cMlnTargetSlots(int32(i))) & " register slot(s))"
                else: "NOT BOUND") &
               ", fired " & $gMlnHits[i] & "x" &
               (if gMlnHits[i] > 0'i64: " first at " & $gMlnFirstMs[i] & "ms"
                else: ""))
    inc i
  result.add("    stages: " & $int(cMlnStageSeen()) & " observed, " &
             $int(cMlnStageCount()) & " recorded, " &
             $int(cMlnStageUndecoded()) & " undecoded")
  result.add("    caption: screen=0x" & hexOf(cast[uint64](gMlnScreen)) &
             " statusField=0x" & hexOf(cast[uint64](gMlnTmp)) &
             ", " & $gMlnWrites & " write(s)" &
             (if gMlnCaptionOff: " -- CAPTION HALF DISABLED (" &
                gMlnCaptionWhy & ")"
              elif gMlnDrove: " -- DRIVING the game's own caption"
              elif gMlnCaptionWhy.len > 0: " -- not driving: " & gMlnCaptionWhy
              else: " -- nothing offered to write yet"))
  result.add("    THE HOLD IS NOT IMPLEMENTED. This feature does not delay " &
             "the boot for the mod build; see the file header and " &
             "docs/BOOT-FLOW-MAP.md Q1. Anything that reads these rows as a " &
             "synchronous wait is reading them wrong.")

proc mlnVerdicts*() =
  ## The four verdicts, printed ONCE, after both the release and the menu-show
  ## event are in. Every one has three outcomes; "I could not look" is
  ## INCONCLUSIVE and never a pass.
  if not gMlnOn or gMlnVerdictSaid: return
  if gMlnReleaseMs == 0'u64 or gModLoadMenuShownAt == 0'u64: return
  gMlnVerdictSaid = true

  # THE CENSUS FIRST, so every verdict below is read beside what was actually
  # bound and what actually fired. Bound to a local: nimony refuses to borrow
  # an iteration path from a call's temporary.
  let rep = mlnReport()
  var ri = 0
  while ri < rep.len:
    info "modload native:" & rep[ri]
    ri = ri + 1

  # (1) STAGES
  let sn = int(cMlnStageSeen())
  if gMlnSlotOfRow[MlnRowBegin] < 0 and gMlnSlotOfRow[MlnRowStartFlow] < 0:
    warn "modload native VERDICT 1 (MenuLoadProfiler stages) INCONCLUSIVE: " &
         "neither profiler row bound, so nothing was measured."
  elif sn == 0:
    warn "modload native VERDICT 1 (MenuLoadProfiler stages) INCONCLUSIVE: " &
         "the rows are BOUND and fired 0 times. The game declared no stage " &
         "this boot, or it declares them before this host arms. That is not " &
         "evidence about the ordering either way."
  else:
    okLog "modload native VERDICT 1 (MenuLoadProfiler stages) MEASURED: " &
          $sn & " stage(s) observed, " & $int(cMlnStageCount()) &
          " recorded, " & $int(cMlnStageUndecoded()) &
          " whose name could not be decoded. Each was logged above with its " &
          "THREAD ID -- that is the live read docs/BOOT-FLOW-MAP.md Q1/Q2 " &
          "asks for, and it is what a hold point for F1 has to be built on."

  # (2) CAPTION
  if not gMlnReadbackDone:
    warn "modload native VERDICT 2 (our text on the game's caption) " &
         "INCONCLUSIVE: no write was ever attempted (" &
         (if gMlnCaptionWhy.len > 0: gMlnCaptionWhy
          else: "no progress line was offered") & ")."
  elif gMlnReadbackPass:
    okLog "modload native VERDICT 2 (our text on the game's caption) PASS: " &
          $gMlnWrites & " write(s), first at " & $gMlnFirstWriteMs &
          "ms; " & gMlnReadbackWhy & "."
  else:
    warn "modload native VERDICT 2 (our text on the game's caption) FAIL: " &
         gMlnReadbackWhy & "."

  # (3) THE RELEASE BEFORE MenuScreen::Show
  #
  # READ THIS BEFORE READING THE NUMBER. With the EXISTING backstop the
  # deferred release is GATED ON `MenuScreen::Show` (modload.nim's
  # `mlGateOpen`), so the release CANNOT precede the show event -- this verdict
  # is FAIL BY CONSTRUCTION whenever that gate is what released the mods. That
  # is not a bug in the measurement; it is the measurement reporting the design
  # the backstop has, and it is exactly why F1 wants a hold EARLIER in the
  # boot. The release paths that CAN pass are the no-file path, the deadline,
  # and a READY that arrived while the gate was open.
  if gMlnReleaseMs < gModLoadMenuShownAt:
    okLog "modload native VERDICT 3 (mods released before the menu) PASS: " &
          "the release was performed on thread " & $int(gMlnReleaseTid) &
          " (ops) at " & $gMlnReleaseMs & "ms, and MenuScreen::Show was " &
          "first observed at " & $gModLoadMenuShownAt & "ms."
  else:
    warn "modload native VERDICT 3 (mods released before the menu) FAIL: " &
         "the release landed at " & $gMlnReleaseMs & "ms on thread " &
         $int(gMlnReleaseTid) & " and MenuScreen::Show was observed at " &
         $gModLoadMenuShownAt & "ms -- NOT earlier. If `deferModLoad`'s gate " &
         "is what released them then this is FAIL BY CONSTRUCTION: that gate " &
         "IS MenuScreen::Show. Moving the release earlier needs a hold " &
         "earlier in the boot, which is BOOT-FLOW-MAP Q1 and is not " &
         "implemented."

  # (4) NO CHARACTER-SELECTION FRAME BEFORE THE RELEASE -- a NEGATIVE, and it
  # rides modeskip's own two drains rather than binding a second detour on the
  # same two functions (which would overwrite modeskip's trampolines).
  if gModeSkipCtorSlot < 0 or gModeSkipShowSlot < 0:
    warn "modload native VERDICT 4 (no character-selection frame before the " &
         "release) INCONCLUSIVE: modeskip's .ctor @0x13F0530 / ShowSlot " &
         "@0x13EFAE0 drains are not both bound (`skipModeScreen` off, or a " &
         "prologue refused), so nothing counted the screen. This host will " &
         "NOT bind a second detour on those two to answer it -- the second " &
         "would overwrite modeskip's trampoline and kill that feature " &
         "silently."
  elif gMlnCtorsAtRelease <= 0 and gMlnSlotsAtRelease <= 0:
    okLog "modload native VERDICT 4 (no character-selection frame before the " &
          "release) PASS: at the instant the release was performed, " &
          "CharacterSelectionScreenController::.ctor had fired " &
          $gMlnCtorsAtRelease & " time(s) and CharacterSelectionScreen::" &
          "ShowSlot " & $gMlnSlotsAtRelease & " time(s)."
  else:
    warn "modload native VERDICT 4 (no character-selection frame before the " &
         "release) FAIL: by the time the release was performed the " &
         "controller had been constructed " & $gMlnCtorsAtRelease &
         " time(s) and ShowSlot had fired " & $gMlnSlotsAtRelease &
         " time(s). Frames of the character-selection screen WERE rendered " &
         "before the mods were released."

proc bindModLoadNative*(verbose: bool): bool =
  ## Bind the four read-only POSTFIX drains. Flag-gated, DEFAULT OFF. Every row
  ## is attempted; a row that does not byte-verify against the startup snapshot
  ## is REFUSED ALOUD and the others still bind, because a partial measurement
  ## is still evidence while a silent partial bind is not.
  if not gMlnOn: return false
  if gMlnBound > 0: return true
  if int(cMlnTargetCount()) != MlnRowCount:
    warn "modload native: the C table has " & $int(cMlnTargetCount()) &
         " row(s) but this file names " & $MlnRowCount & ". That is a source " &
         "drift in THIS repo, not a game build difference. REFUSING to bind " &
         "rather than index one table by the other's count."
    return false
  var i = 0
  while i < MlnRowCount:
    let spec = mlnRowName(i)
    let fn = cMlnTargetAt(int32(i))
    if fn == nil:
      if gMlnNotBound.len > 0: gMlnNotBound.add ", "
      gMlnNotBound.add spec
      warn "modload native: " & spec & " @0x" &
           hexOf(uint64(cMlnTargetRva(int32(i)))) & " did NOT verify against " &
           "the STARTUP PROLOGUE SNAPSHOT on this build, so it is NOT bound. " &
           "Two causes and they need different answers: a different game " &
           "build, or another feature patched it before our first verify (a " &
           "HOOK ORDER problem, not a bad RVA -- nothing in this host binds " &
           "these four today; TryCreateInRaidCharacterSelection is NOT one of " &
           "our rows, precisely because modeskip.nim already binds it). " & $int(cMlnRejected()) &
           " row(s) rejected so far."
    else:
      gMlnArming = i
      let okBind = attachDrain(spec, fn, cast[Il2CppMethod](0), false, verbose,
                               35'i32, true, cMlnTargetSlots(int32(i)))
      gMlnArming = -1
      if okBind:
        inc gMlnBound
      else:
        if gMlnNotBound.len > 0: gMlnNotBound.add ", "
        gMlnNotBound.add spec & " (attach refused)"
    inc i
  if gMlnBound == 0:
    warn "modload native: ARMED BUT BOUND NOTHING (" & gMlnNotBound &
         "). Nothing is measured, no caption is driven, and modload.nim's own " &
         "overlay keeps running. This is INCONCLUSIVE, not a working feature."
    return false
  okLog "modload native ARMED: " & $gMlnBound & "/" & $MlnRowCount &
        " read-only POSTFIX drains bound (MenuLoadProfiler StartFlow/Begin, " &
        "ProfileLoadingScreen Show/SetLivingStatus -- all UNIQUE, all " &
        "verified against the startup prologue snapshot, all <= 4 register " &
        "slots; TryCreateInRaidCharacterSelection is deliberately NOT bound, " &
        "because modeskip.nim already owns that RVA). It " &
        "LOGS the game's own boot stages with their thread ids and DRIVES " &
        "the game's own profile-loading caption with the mod-build progress. " &
        "It takes no bypass, delays no step and changes NO return value: the " &
        "deferred release stays gated on MenuScreen::Show behind " &
        "`deferModLoad`, exactly as before."
  true
