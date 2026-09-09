# hostfieldwrite.nim -- THE TYPED STORE PATH.
#
# `include`d into `aowlhost.nim` EARLY (before botcap/botai/nativeui), because
# those are the sites that must use it and Nim's `include` is textual. It
# therefore depends on NOTHING but `Il2CppPtr`, `hexOf`, `okLog` and `warn`.
#
# WHAT THIS IS FOR (docs/INTERACTION-LAYER-MAP.md M3/M6, WRITE-AUDIT section 5)
# ============================================================================
# Every store into game-owned memory in this tree was handed a BARE OFFSET and
# guarded by READABILITY. On the IL2CPP GC heap readability cannot fail -- the
# pages stay mapped after an object dies -- so a stale pointer into recycled
# memory passed every guard and the write landed in whatever type now owns the
# address. A check that cannot fail IS the bug (CLAUDE.md 9b).
#
# A bare offset also cannot answer the question that produced the crash: is
# this slot a managed REFERENCE? A 4-byte store of -1 into a reference slot
# whose upper dword was zero is exactly `0x00000000FFFFFFFF`, the value in RCX
# when `il2cpp_unity_liveness_calculation_from_root` died.
#
# So the offset is no longer an integer literal. It is an `AowlFieldRef`
# generated from `Il2CppMetadataRegistration.fieldOffsets` by
# `tools/fieldrefs.py` into `abi/aowlspt_fieldrefs.h`, carrying the type name,
# field name, offset, WIDTH, IS_REFERENCE and a lower bound on the instance
# size. `abi/aowlspt_hostwrite.h`'s `aowl_fr_gate` refuses on five grounds; the
# messages below name each one AND the value it refused.
#
# WHAT IT DOES NOT DO, said plainly
# =================================
# * NO Unity liveness test. `nuAlive` lives in `nativeui.nim`, which is
#   included later than this file has to be. A receiver captured on a screen
#   that can close must ALSO go through `hostRecvOk` in `hostwrite.nim`; this
#   layer catches the wrong TYPE, not a destroyed object of the right type.
# * The instance-size bound is WEAK BY CONSTRUCTION for a generated FieldRef
#   (the offset came out of the same table as the bound). It cannot fire except
#   on a hand-edited or stale header, and it is kept only because that is a
#   real failure mode and the check is free.
# * Klass admission is TRUST-ON-FIRST-USE. It is strong against GC recycling --
#   the measured crash class -- and it is NOT a defence against admitting the
#   wrong klass in the first place. That is why `frAdmit` is a separate call
#   each site has to justify in a comment.

# ---------------------------------------------------------------------------
# The C side. `AowlFieldRef` is opaque here on purpose: nothing in Nim may
# construct one, so a store cannot be made against an offset the resolver never
# produced (WRITE-AUDIT section 5.4).
# ---------------------------------------------------------------------------
type AowlFieldRefPtr = Il2CppPtr

proc cFrAdmit(fr, recv: AowlFieldRefPtr): int32 {.
  importc: "aowl_fr_admit", nodecl.}
proc cFrKlassOf(fr, recv: AowlFieldRefPtr): Il2CppPtr {.
  importc: "aowl_fr_klass_of", nodecl.}
proc cFrRecvOk(fr, recv: AowlFieldRefPtr; why: var int32): int32 {.
  importc: "aowl_fr_recv_ok", nodecl.}
proc cFrStoreU8(fr, recv: AowlFieldRefPtr; sub: int32; v: uint8;
                why: var int32): int32 {.importc: "aowl_fr_store_u8", nodecl.}
proc cFrStoreI32(fr, recv: AowlFieldRefPtr; sub: int32; v: int32;
                 why: var int32): int32 {.importc: "aowl_fr_store_i32", nodecl.}
proc cFrStoreF32(fr, recv: AowlFieldRefPtr; sub: int32; v: float32;
                 why: var int32): int32 {.importc: "aowl_fr_store_f32", nodecl.}
proc cFrStorePtr(fr, recv: AowlFieldRefPtr; sub: int32; v: Il2CppPtr;
                 why: var int32): int32 {.importc: "aowl_fr_store_ptr", nodecl.}
proc cFrType(fr: AowlFieldRefPtr): cstring {.importc: "aowl_fr_type", nodecl.}
proc cFrField(fr: AowlFieldRefPtr): cstring {.importc: "aowl_fr_field", nodecl.}
proc cFrOff(fr: AowlFieldRefPtr): int32 {.importc: "aowl_fr_off", nodecl.}
proc cFrWidth(fr: AowlFieldRefPtr): int32 {.importc: "aowl_fr_width", nodecl.}
proc cFrIsRef(fr: AowlFieldRefPtr): int32 {.importc: "aowl_fr_isref", nodecl.}
proc cFrNKlass(fr: AowlFieldRefPtr): int32 {.importc: "aowl_fr_nklass", nodecl.}
# ADVISORY ONLY, for the inspector's deliberately raw `write` verb. Neither
# writes nor refuses; see the block comment in `abi/aowlspt_hostwrite.h`.
proc cFrLookup(p: Il2CppPtr; n: int32; why: var int32): int32 {.
  importc: "aowl_fr_lookup", nodecl.}
proc cFrRowType(r: int32): cstring {.importc: "aowl_fr_row_type", nodecl.}
proc cFrRowField(r: int32): cstring {.importc: "aowl_fr_row_field", nodecl.}
proc cFrRowIsRef(r: int32): int32 {.importc: "aowl_fr_row_isref", nodecl.}
proc cFrRowWidth(r: int32): int32 {.importc: "aowl_fr_row_width", nodecl.}

proc cFrRefNarrow(): int64 {.importc: "aowl_fr_refused_narrow_ref", nodecl.}
proc cFrRefWidth(): int64 {.importc: "aowl_fr_refused_width", nodecl.}
proc cFrRefKlass(): int64 {.importc: "aowl_fr_refused_klass", nodecl.}
proc cFrAdmitted(): int64 {.importc: "aowl_fr_admitted", nodecl.}

# The generated rows, each through its own C accessor.
#
# NEVER `importc: "(&AOWL_FR_X)"`. MEASURED 2026-09-03: `importc` on a PROC
# emits a CALL, so that spelling compiles to `(&AOWL_FR_X)()` and gcc says
# "called object is not a function or function pointer". The accessors are
# generated alongside the rows for exactly this reason -- and going through a
# function also keeps `AowlFieldRef`'s layout entirely on the C side, so Nim
# cannot be made to disagree with it.
proc frBcMaxBots(): AowlFieldRefPtr {.importc: "aowl_fr_bc_maxbots", nodecl.}
proc frBaIsReady(): AowlFieldRefPtr {.importc: "aowl_fr_ba_isready", nodecl.}
proc frGraphicColor(): AowlFieldRefPtr {.importc: "aowl_fr_graphic_color", nodecl.}
proc frTmpFontAsset(): AowlFieldRefPtr {.importc: "aowl_fr_tmp_fontasset", nodecl.}
proc frTmpSharedMat(): AowlFieldRefPtr {.importc: "aowl_fr_tmp_sharedmat", nodecl.}
proc frGraphicMat(): AowlFieldRefPtr {.importc: "aowl_fr_graphic_mat", nodecl.}
proc frToggleGroup(): AowlFieldRefPtr {.importc: "aowl_fr_toggle_group", nodecl.}
proc frToggleIsOn(): AowlFieldRefPtr {.importc: "aowl_fr_toggle_ison", nodecl.}
proc frTmpMText(): AowlFieldRefPtr {.importc: "aowl_fr_tmp_mtext", nodecl.}
proc frEbPath(): AowlFieldRefPtr {.importc: "aowl_fr_eb_path", nodecl.}
# APPENDED 2026-09-04 -- the six fields of the `SettingsTooltipData` TEMPLATE
# `SettingControl::SetTooltip` @0x16FAC00 reads. Widths and is-reference bits
# are DERIVED by tools/fieldrefs.py from the metadata, never spelled here.
proc frTtdKey(): AowlFieldRefPtr {.importc: "aowl_fr_ttd_key", nodecl.}
proc frTtdTitle(): AowlFieldRefPtr {.importc: "aowl_fr_ttd_title", nodecl.}
proc frTtdText(): AowlFieldRefPtr {.importc: "aowl_fr_ttd_text", nodecl.}
proc frTtdUsageStyle(): AowlFieldRefPtr {.
  importc: "aowl_fr_ttd_usagestyle", nodecl.}
proc frTtdUsageProp(): AowlFieldRefPtr {.
  importc: "aowl_fr_ttd_usageprop", nodecl.}
proc frTtdUsageText(): AowlFieldRefPtr {.
  importc: "aowl_fr_ttd_usagetext", nodecl.}
# APPENDED 2026-09-04 -- Prism's AO block, for `nativepostfx.nim` rows 2 and 3.
# These are the ONE part of the native POSTFX row set that is a STORE rather
# than a call: MEASURED `tools/fldoff.py fields PrismEffects`, they are PUBLIC
# instance fields the Prism scripts sample every frame and there is no applier
# method to call.
#
# The klass admission is doing real work here, not ceremony. The receiver is
# walked from `CameraManager._prismEffects@0xE8` (typed `PrismEffects`), while
# a near-identical AO block also exists on `PrismSSAO` at COMPLETELY different
# offsets (`aoIntensity@0xA4` vs `@0x27C`). A store of 0x27C onto a PrismSSAO
# receiver would land mid-field and read back plausibly; `aowl_fr_recvok` is
# what refuses it. Widths and is-reference bits are DERIVED by
# tools/fieldrefs.py from the metadata, never spelled here.
proc frPeAoIntensity(): AowlFieldRefPtr {.
  importc: "aowl_fr_pe_ao_intensity", nodecl.}
proc frPeAoRadius(): AowlFieldRefPtr {.
  importc: "aowl_fr_pe_ao_radius", nodecl.}
proc frPeAoBlurIter(): AowlFieldRefPtr {.
  importc: "aowl_fr_pe_ao_bluriter", nodecl.}

# ---------------------------------------------------------------------------
# Refusal reporting. Capped per site so a per-frame path cannot flood the log,
# and the CAP IS THE ONLY THING CAPPED -- the refusal itself always happens.
# ---------------------------------------------------------------------------
const FrSayPerSite = 6
const FrMaxSites = 48

var gFrSite: seq[string] = @[]
var gFrSaid: seq[int32] = @[]

proc frSiteIdx(site: string): int =
  var i = 0
  while i < gFrSite.len:
    if gFrSite[i] == site: return i
    i = i + 1
  if gFrSite.len >= FrMaxSites: return -1
  gFrSite.add site
  gFrSaid.add 0'i32
  gFrSite.len - 1

proc frWhyText(why: int32; fr: AowlFieldRefPtr; recv: Il2CppPtr;
               sub, n: int32): string =
  ## The refusal NAMES THE VALUE IT REFUSED (map section 7, rule 11).
  case why
  of 1'i32:
    "fieldref: R1 narrow-into-reference -- " & $cFrType(fr) & "." &
    $cFrField(fr) & " is declared a managed REFERENCE by the metadata, so it " &
    "is 8 bytes written whole or it is not written at all; this site asked " &
    "for " & $int(n) & " byte(s) at sub-offset " & $int(sub) & ". A 4-byte " &
    "store of -1 into a zeroed reference slot IS the 0x00000000FFFFFFFF that " &
    "killed the liveness walk"
  of 2'i32:
    "fieldref: R2 too-wide -- " & $cFrType(fr) & "." & $cFrField(fr) &
    " is " & $int(cFrWidth(fr)) & " byte(s) wide, and this site asked for " &
    $int(n) & " byte(s) at sub-offset " & $int(sub)
  of 3'i32:
    "fieldref: R3 klass -- receiver 0x" & hexOf(cast[uint64](recv)) &
    " presents klass 0x" & hexOf(cast[uint64](cFrKlassOf(fr, recv))) &
    ", which is not one of the " & $int(cFrNKlass(fr)) & " klass(es) admitted " &
    "for " & $cFrType(fr) & "." & $cFrField(fr) & ". That is what a stale " &
    "pointer into recycled GC memory looks like -- and zero admitted klasses " &
    "refuses everything, deliberately"
  of 4'i32:
    "fieldref: R4 receiver -- 0x" & hexOf(cast[uint64](recv)) &
    " is null, or the span at +0x" & hexOf(uint64(cFrOff(fr) + sub)) &
    " is not readable/writable"
  of 5'i32:
    "fieldref: R5 bound -- +0x" & hexOf(uint64(cFrOff(fr) + sub)) & " + " &
    $int(n) & " lies outside the declared instance size of " & $cFrType(fr)
  else:
    "fieldref: R6 unusable FieldRef -- null, or width 0, which means " &
    "tools/fieldrefs.py could not derive the width from the metadata and " &
    "refused to guess it"

proc frSay(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr;
           sub, n, why: int32) =
  if why == 0'i32: return
  let i = frSiteIdx(site)
  if i < 0: return
  if gFrSaid[i] >= FrSayPerSite:
    return
  gFrSaid[i] = gFrSaid[i] + 1'i32
  warn "hostwrite REFUSED [" & site & "] " & frWhyText(why, fr, recv, sub, n) &
       (if gFrSaid[i] == FrSayPerSite:
          " (further refusals at this site are counted, not logged)"
        else: "")

# ---------------------------------------------------------------------------
# THE PUBLIC API. Nothing else in host/ or mods/ may store into managed memory;
# `tools/storelint.py` fails the build on a raw cast-store outside this pair of
# files.
# ---------------------------------------------------------------------------

proc frAdmit*(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr): bool =
  ## Record `recv`'s klass as legitimate for this FieldRef.
  ##
  ## CALL THIS ONLY where the receiver's type is a FACT -- a detour's `this` on
  ## a method that type declares, or an object the game itself just handed
  ## back. "It read back plausibly" is not a fact and is exactly the reasoning
  ## the crash came from.
  result = cFrAdmit(fr, recv) != 0'i32
  if not result:
    warn "hostwrite REFUSED [" & site & "] fieldref: admission refused for " &
         $cFrType(fr) & "." & $cFrField(fr) & " -- receiver 0x" &
         hexOf(cast[uint64](recv)) & " is null/unreadable, or the klass " &
         "allowlist is already full (a full allowlist means this FieldRef is " &
         "seeing more concrete types than it should; widening it would turn " &
         "the check into one that cannot fail)"

proc frRecvOk*(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr): bool =
  ## For a field written by CALLING a game setter. No offset to bound; the
  ## receiver's TYPE is the whole of the protection, and it is the thing that
  ## was missing in both crash dumps.
  var why = 0'i32
  result = cFrRecvOk(fr, recv, why) != 0'i32
  if not result: frSay(site, fr, recv, 0'i32, 0'i32, why)

proc frStoreU8*(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr;
                v: uint8; sub: int32 = 0'i32): bool =
  var why = 0'i32
  result = cFrStoreU8(fr, recv, sub, v, why) != 0'i32
  if not result: frSay(site, fr, recv, sub, 1'i32, why)

proc frStoreI32*(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr;
                 v: int32; sub: int32 = 0'i32): bool =
  var why = 0'i32
  result = cFrStoreI32(fr, recv, sub, v, why) != 0'i32
  if not result: frSay(site, fr, recv, sub, 4'i32, why)

proc frStoreF32*(site: string; fr: AowlFieldRefPtr; recv: Il2CppPtr;
                 v: float32; sub: int32 = 0'i32): bool =
  var why = 0'i32
  result = cFrStoreF32(fr, recv, sub, v, why) != 0'i32
  if not result: frSay(site, fr, recv, sub, 4'i32, why)

proc frStorePtr*(site: string; fr: AowlFieldRefPtr; recv, v: Il2CppPtr;
                 sub: int32 = 0'i32): bool =
  ## The only 8-byte reference store in the tree. `sub` exists for symmetry and
  ## is refused by R1 for a reference field unless it is 0.
  var why = 0'i32
  result = cFrStorePtr(fr, recv, sub, v, why) != 0'i32
  if not result: frSay(site, fr, recv, sub, 8'i32, why)

proc frSummary*(): string =
  "fieldref: admitted=" & $cFrAdmitted() & " refusedNarrowRef=" &
  $cFrRefNarrow() & " refusedWidth=" & $cFrRefWidth() & " refusedKlass=" &
  $cFrRefKlass()
