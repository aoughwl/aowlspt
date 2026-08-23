## loadprobe.nim — ONE raid, twelve counters, one ranked answer.
##
## ---------------------------------------------------------------------------
## THE MEASUREMENT THIS EXISTS TO REPLACE
## ---------------------------------------------------------------------------
##
## `swap.nim` installed a typed POSTFIX on `UnityEngine.AssetBundle::LoadAsset`
## (rid=6, RVA 0x5250100) and it installed PERFECTLY — prologue byte-verified,
## host reported `hooked`, mode `probe` ARMED — and then **never fired once**
## across a full offline raid (18 `botdiag: RegisterPlayer` events confirming
## in-raid; `"fires":0` in every 10-second `swapStats` readout).
##
## So the install machinery is proven and the TARGET is wrong: post-1.0 Tarkov
## does not call the public synchronous `LoadAsset(string)`. The original
## TarkovTextures plugin patched it on the pre-1.0 **Mono** build, where the
## generic `LoadAsset<T>` and the async path both funnelled somewhere this one
## does not.
##
## Re-aiming one guess at a time costs one raid per guess. This aims at every
## plausible entry point of `UnityEngine.AssetBundle` AT ONCE and counts, so a
## single raid RANKS them.
##
## ---------------------------------------------------------------------------
## WHY PREFIXES, NOT POSTFIXES
## ---------------------------------------------------------------------------
##
## A postfix must CALL the original from inside the thunk's own frame and come
## back with its result — which is why the host derives (or, for an RVA patch,
## demands) `frameKinds` / `retKind` / `methodIsStatic`, and why
## `rvaPostfixRefusal` exists at all. Twelve postfixes is twelve frame shapes to
## get exactly right, and a wrong one is a hook that installs cleanly and is
## silently corrupt.
##
## A PREFIX tail-jumps into the trampoline: the return value, the stack
## arguments and the return address are correct by construction, because the
## original still runs with the frame the caller built. For COUNTING we never
## read an argument and never touch a result, so no shape can be wrong in a way
## that matters.
##
## THE SHAPE IS STILL MANDATORY, AND THAT IS A HOST FACT, NOT A CHOICE.
## `parseRvaSpec` in `host/Aowlspt.Host.Il2Cpp/aowlhost.nim` refuses **any**
## `@0x` spec with an empty shape — the refusal is unconditional and does not
## look at `PatchKind`, so a prefix cannot omit it either. The shapes declared
## below are therefore stated, and they are stated as INFERRED from Unity's
## public `AssetBundle` API rather than measured: there is no `MethodInfo` on
## this build to read them from. On a prefix that reads nothing they are inert.
## Do NOT copy them onto a postfix.
##
## ---------------------------------------------------------------------------
## SAFETY
## ---------------------------------------------------------------------------
##
##  * **Default OFF.** Nothing here installs unless `probeTargets` is set to a
##    non-empty, non-"off" value. Shipping defaults are untouched.
##  * **Mutually exclusive with the swap.** `swap.nim` postfixes rid=6. Two
##    detours on one function means the second overwrites the first's
##    trampoline and the first silently dies, so if `swapMode` is anything but
##    `off` the WHOLE probe refuses and says why. It does not quietly drop the
##    overlapping target and pretend the rest is a clean measurement.
##  * **Per-target byte verification.** Each RVA's 16 live bytes are compared
##    against the bytes this build compiled (read offline from
##    `D:/Games/Tarkov/GameAssembly.dll`) before the mod hands the address to
##    the host — and the same 16 go into the spec's `!` suffix so the host
##    re-verifies them against its own STARTUP SNAPSHOT, which is the compare
##    that stays right if something else detoured the function first. A
##    mismatch refuses THAT target, names it, and the rest still install.
##  * **Every hop VirtualQuery'd** (`aowl_lp_readable`), capped iteration
##    everywhere (fixed 12-entry table, a 16-byte read, a bounded rid parse).
##  * **No guard inside the hook.** `aowl_p_p_seh` is not re-entrant and these
##    handlers run inside the host's typed-fire path; an inner guard would
##    DISARM the outer one. Safety here comes from the body being incapable of
##    faulting: one `inc` on a module-static counter and `frameContinue()`.
##    No allocation, no name read, no logging, no pointer dereference.
##  * **Self-disable.** A target that refuses is never retried; arming is
##    one-shot (`gLpTried`), so a refusal is one honest line, not a log storm.
##
## ---------------------------------------------------------------------------
## THE CONTROL
## ---------------------------------------------------------------------------
##
## rid=6 stays in the table as a CONTROL. It was measured at zero over a full
## raid, so if the counting were counting everything it would show up here as a
## non-zero rid=6. A zero rid=6 next to a non-zero anything-else is what makes
## the ranking honest.
##
## rid=7 is the one to watch: `LoadAsset<T>(name)` and the public
## `LoadAsset(name)` both lower to `LoadAsset(string, Type)` in Unity's managed
## source, so it — not rid=6 — is the synchronous chokepoint. That is a
## prediction from Unity's public API, not a measurement; the raid decides.

import std/strutils
import aowlspt
import aowlspt/game
import aowlspt/il2cpp

# --------------------------------------------------------------------------
# Native helpers. Deliberately NOT shared with swap.nim's `aowl_tex_*` block:
# separate names, separate file, so this probe adds nothing to a shim another
# worktree may be editing.
# --------------------------------------------------------------------------
{.emit: """
#include <windows.h>
#include <string.h>
static int aowl_lp_readable(const void* p, int n) {
  MEMORY_BASIC_INFORMATION mbi;
  if (!p || n <= 0) return 0;
  if (!VirtualQuery(p, &mbi, sizeof(mbi))) return 0;
  if (mbi.State != MEM_COMMIT) return 0;
  if (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
  {
    unsigned long long end = (unsigned long long)mbi.BaseAddress + mbi.RegionSize;
    return ((unsigned long long)p + (unsigned long long)n <= end) ? 1 : 0;
  }
}
/* GameAssembly.dll's ACTUAL base. 0x180000000 is the PE PREFERRED base -- the
 * space tools/il2cpp_resolve.py reports RVAs in -- and the module is
 * ASLR-relocated in the live process. Never hardcode it. */
static void* aowl_lp_rva(unsigned int rva) {
  HMODULE ga = GetModuleHandleA("GameAssembly.dll");
  if (!ga) return NULL;
  return (void*)((unsigned char*)ga + rva);
}
static int aowl_lp_readcode(const void* p, unsigned char* out, int n) {
  if (!aowl_lp_readable(p, n)) return 0;
  memcpy(out, p, (size_t)n);
  return n;
}
""".}
proc lpReadable(p: Il2CppPtr; n: int32): int32 {.
  importc: "aowl_lp_readable", nodecl.}
proc lpRva(rva: uint32): Il2CppPtr {.importc: "aowl_lp_rva", nodecl.}
proc lpReadCode(p, outp: Il2CppPtr; n: int32): int32 {.
  importc: "aowl_lp_readcode", nodecl.}

# --------------------------------------------------------------------------
# The target table
# --------------------------------------------------------------------------
#
# Every RVA below was produced by, and re-verified against:
#
#   python tools/il2cpp_resolve.py D:/Games/Tarkov/GameAssembly.dll \
#          .cache/global-metadata.dec.dat type 30974
#
# on build 1.1.0.1.46777 (type 30974 = UnityEngine.AssetBundle, image
# UnityEngine.AssetBundleModule.dll). The 16 prologue bytes were read out of
# the SAME GameAssembly.dll at the file offset the PE section table maps each
# RVA to — all twelve land in the `il2cpp` section, which is where generated
# code lives on this build (never `.text`).

const
  LpN = 12

  ## rid, purely for the report and the `probeTargets` selector.
  LpRid: array[LpN, int] = [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 19]

  LpRvaTab: array[LpN, uint32] = [
    0x5250100'u32,   # 6  LoadAsset(string)                        CONTROL
    0x5250340'u32,   # 7  LoadAsset(string, Type)
    0x52504e0'u32,   # 8  LoadAsset_Internal(string, Type)
    0x5250550'u32,   # 9  LoadAssetAsync(string)
    0x5250630'u32,   # 10 LoadAssetAsync(string, Type)
    0x52507d0'u32,   # 11 LoadAllAssets()
    0x5250980'u32,   # 12 LoadAllAssets(Type)
    0x5250a90'u32,   # 13 LoadAllAssetsAsync()
    0x5250c40'u32,   # 14 LoadAllAssetsAsync(Type)
    0x5250d50'u32,   # 15 LoadAssetAsync_Internal(string, Type)
    0x5250e70'u32,   # 18 LoadAssetWithSubAssets_Internal(string, Type)
    0x5250ee0'u32]   # 19 LoadAssetWithSubAssetsAsync_Internal(string, Type)

  LpName: array[LpN, string] = [
    "LoadAsset", "LoadAsset", "LoadAsset_Internal",
    "LoadAssetAsync", "LoadAssetAsync",
    "LoadAllAssets", "LoadAllAssets",
    "LoadAllAssetsAsync", "LoadAllAssetsAsync",
    "LoadAssetAsync_Internal",
    "LoadAssetWithSubAssets_Internal",
    "LoadAssetWithSubAssetsAsync_Internal"]

  ## The DECLARED frame shape. INFERRED from Unity's public AssetBundle API,
  ## not measured — there is no MethodInfo behind an RVA on this build. Inert
  ## on a prefix that reads nothing; do not reuse on a postfix. `i` = instance,
  ## `o` = object/string/reference argument, `>o` = returns a reference.
  LpShape: array[LpN, string] = [
    "io>o",    # 6  (string)
    "ioo>o",   # 7  (string, Type)
    "ioo>o",   # 8  (string, Type)
    "io>o",    # 9  (string)
    "ioo>o",   # 10 (string, Type)
    "i>o",     # 11 ()
    "io>o",    # 12 (Type)
    "i>o",     # 13 ()
    "io>o",    # 14 (Type)
    "ioo>o",   # 15 (string, Type)
    "ioo>o",   # 18 (string, Type)
    "ioo>o"]   # 19 (string, Type)

  ## The 16 bytes each of these functions begins with in
  ## D:/Games/Tarkov/GameAssembly.dll on build 1.1.0.1.46777. rids 11..14 carry
  ## a RIP-relative `cmp byte[rip+disp32],0` starting at byte 10 (IL2CPP's
  ## class-init preamble); the displacement is exactly what pins the signature
  ## to this build, and the first ten bytes — `mov [rsp+10],rbx ; push rsi ;
  ## sub rsp,0x20` — are position-independent, which is what the detour
  ## engine's steal-and-relocate needs.
  LpPro: array[LpN, string] = [
    "48895C24084889742410574883EC2080",
    "48895C24084889742410574883EC2080",
    "48895C24084889742410574883EC2048",
    "48895C24084889742410574883EC2080",
    "48895C24084889742410574883EC2080",
    "48895C2410564883EC20803DF11AE801",
    "48895C2410564883EC20803D4219E801",
    "48895C2410564883EC20803D3318E801",
    "48895C2410564883EC20803D8416E801",
    "48895C24084889742410574883EC2048",
    "48895C24084889742410574883EC2048",
    "48895C24084889742410574883EC2048"]

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

## THE COUNTERS. Written by the hook bodies on the game's thread, read by the
## report on the mod tick. A plain module-static array of integers: the whole
## point is that the hook body cannot fault, so there is nothing here to guard.
var gLpCount: array[LpN, int64] = [
  0'i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

## Which targets the config asked for, and which actually installed. Kept apart
## deliberately: "asked for and refused" and "never asked for" must never read
## the same in the report.
var gLpWanted: array[LpN, bool] = [
  false, false, false, false, false, false,
  false, false, false, false, false, false]
var gLpBound: array[LpN, bool] = [
  false, false, false, false, false, false,
  false, false, false, false, false, false]

var gLpEnabled = false        ## `probeTargets` named at least one target
var gLpBlocked = ""           ## non-empty: the whole probe refused, and why
var gLpTried = false          ## arming is one-shot
var gLpArmed = false
var gLpInstalled = 0
var gLpRefused = 0
var gLpDelayMs = 0'i64
var gLpLoadedAtMs = 0'i64

proc loadProbeArmed*(): bool = gLpArmed
proc loadProbeEnabled*(): bool = gLpEnabled

# --------------------------------------------------------------------------
# THE HOOK BODIES
# --------------------------------------------------------------------------
#
# Twelve of them, because a `PatchFrame` carries no target identity — there is
# no `frameRva()` or cookie readable from the handler — so the ONLY way to know
# which of twelve fired is twelve distinct handler procs. (That is a genuine
# gap in the typed-patch ABI and is called out in the report; a `frameCookie()`
# would collapse this whole block to one proc and a table index.)
#
# Each body is an increment and a return. Nothing else may ever go in here:
# these are per-asset-load hot paths and a raid loads thousands.

proc lpFire0(f: PatchFrame): TypedResult =
  gLpCount[0] = gLpCount[0] + 1
  frameContinue()
proc lpFire1(f: PatchFrame): TypedResult =
  gLpCount[1] = gLpCount[1] + 1
  frameContinue()
proc lpFire2(f: PatchFrame): TypedResult =
  gLpCount[2] = gLpCount[2] + 1
  frameContinue()
proc lpFire3(f: PatchFrame): TypedResult =
  gLpCount[3] = gLpCount[3] + 1
  frameContinue()
proc lpFire4(f: PatchFrame): TypedResult =
  gLpCount[4] = gLpCount[4] + 1
  frameContinue()
proc lpFire5(f: PatchFrame): TypedResult =
  gLpCount[5] = gLpCount[5] + 1
  frameContinue()
proc lpFire6(f: PatchFrame): TypedResult =
  gLpCount[6] = gLpCount[6] + 1
  frameContinue()
proc lpFire7(f: PatchFrame): TypedResult =
  gLpCount[7] = gLpCount[7] + 1
  frameContinue()
proc lpFire8(f: PatchFrame): TypedResult =
  gLpCount[8] = gLpCount[8] + 1
  frameContinue()
proc lpFire9(f: PatchFrame): TypedResult =
  gLpCount[9] = gLpCount[9] + 1
  frameContinue()
proc lpFire10(f: PatchFrame): TypedResult =
  gLpCount[10] = gLpCount[10] + 1
  frameContinue()
proc lpFire11(f: PatchFrame): TypedResult =
  gLpCount[11] = gLpCount[11] + 1
  frameContinue()

proc lpHandler(i: int): TypedPatchHandler =
  ## The table index -> its handler. A `case` and not an array of procs,
  ## because the mapping must be impossible to get subtly wrong at init time.
  case i
  of 0: lpFire0
  of 1: lpFire1
  of 2: lpFire2
  of 3: lpFire3
  of 4: lpFire4
  of 5: lpFire5
  of 6: lpFire6
  of 7: lpFire7
  of 8: lpFire8
  of 9: lpFire9
  of 10: lpFire10
  else: lpFire11

# --------------------------------------------------------------------------
# Hex, locally (Nimony's strutils has no toHex)
# --------------------------------------------------------------------------

proc lpHex2(b: uint8): string =
  const D = "0123456789ABCDEF"
  result = $D[int(b shr 4)] & $D[int(b and 0x0F'u8)]

proc lpBytesHex(b: openArray[uint8]): string =
  result = ""
  for i in 0 ..< b.len:
    result = result & lpHex2(b[i])

proc lpRvaHex(v: uint32): string =
  const D = "0123456789ABCDEF"
  var x = v
  if x == 0'u32:
    return "0"
  var buf = ""
  while x != 0'u32:
    buf = buf & $D[int(x and 0xF'u32)]
    x = x shr 4
  result = ""
  var k = buf.len - 1
  while k >= 0:
    result = result & $buf[k]
    dec k

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

proc lpSelectAll() =
  for i in 0 ..< LpN:
    gLpWanted[i] = true

proc configureLoadProbe*(targets: string; swapMode: string;
                         armDelayMs: int) =
  ## Records what the probe will do; installs nothing. Called from onLoad.
  ##
  ## `targets`: "" or "off" = disabled (the shipping default). "all" = every
  ## entry in the table. Otherwise a comma-separated list of rids, e.g.
  ## "7,10,15" — an unknown rid is NAMED rather than ignored.
  gLpEnabled = false
  gLpBlocked = ""
  gLpDelayMs = int64(armDelayMs)
  gLpLoadedAtMs = nowMs()
  for i in 0 ..< LpN:
    gLpWanted[i] = false

  let t = strip(targets)
  if t.len == 0 or t == "off":
    return

  # THE DOUBLE-DETOUR REFUSAL. `swap.nim` postfixes rid=6 at 0x5250100. Two
  # detours on one function means the second overwrites the first's trampoline
  # and the first silently dies — so the probe does not "helpfully" drop rid=6
  # and run the other eleven. It refuses whole and says so: a probe run
  # alongside a live swap is not a clean measurement of anything.
  if swapMode.len > 0 and swapMode != "off":
    gLpBlocked = "probeTargets is set but swapMode is '" & swapMode &
      "', which arms swap.nim's own postfix on rid=6 (LoadAsset@0x5250100). " &
      "Two detours on one function: the second overwrites the first's " &
      "trampoline and the first silently dies. The probe REFUSES entirely " &
      "rather than run a measurement that is contaminated by the swap. Set " &
      "swapMode to 'off' for the probe raid."
    return

  if t == "all":
    lpSelectAll()
  else:
    # A bounded parse: at most LpN + 8 fields, each at most 4 characters.
    var fields = split(t, ",")
    if fields.len > LpN + 8:
      gLpBlocked = "probeTargets lists " & $fields.len & " entries; the table " &
        "holds " & $LpN & ". Refusing rather than truncating."
      return
    for k in 0 ..< fields.len:
      let f = strip(fields[k])
      if f.len == 0:
        continue
      var found = false
      for i in 0 ..< LpN:
        if f == $LpRid[i]:
          gLpWanted[i] = true
          found = true
      if not found:
        warn "textures  loadprobe: probeTargets names rid=" & f &
             ", which is not in the AssetBundle target table; IGNORED. " &
             "Known rids: 6 7 8 9 10 11 12 13 14 15 18 19, or 'all'."

  for i in 0 ..< LpN:
    if gLpWanted[i]:
      gLpEnabled = true
  if not gLpEnabled:
    gLpBlocked = "probeTargets = '" & targets &
      "' selected no known target; nothing will be installed."

# --------------------------------------------------------------------------
# Verification + install
# --------------------------------------------------------------------------

proc lpVerify(i: int; outFn: var Il2CppPtr): string =
  ## The mod's own compare, before the host's. Reads LIVE bytes, so it is only
  ## right because nothing else in this host detours these twelve — the whole
  ## reason the same 16 bytes also go into the spec's `!` suffix, where the
  ## host compares them against its STARTUP SNAPSHOT instead. If this ever
  ## mismatches on an RVA known good, suspect hook ORDER before suspecting the
  ## address; the message below says so.
  outFn = cast[Il2CppPtr](0)
  let rva = LpRvaTab[i]
  let fn = lpRva(rva)
  if cast[uint](fn) == 0'u:
    return "GameAssembly.dll is not mapped (GetModuleHandleA returned NULL)"
  if lpReadable(fn, 16'i32) == 0'i32:
    return "the 16 bytes at GameAssembly+0x" & lpRvaHex(rva) &
           " are not committed and readable"
  var buf: array[16, uint8] = [0'u8, 0, 0, 0, 0, 0, 0, 0,
                               0, 0, 0, 0, 0, 0, 0, 0]
  if lpReadCode(fn, cast[Il2CppPtr](addr buf[0]), 16'i32) != 16'i32:
    return "the 16 bytes at GameAssembly+0x" & lpRvaHex(rva) & " read short"
  let got = lpBytesHex(buf)
  if got != LpPro[i]:
    return "prologue MISMATCH at GameAssembly+0x" & lpRvaHex(rva) &
           " — refusing to patch. got [" & got & "] expected [" & LpPro[i] &
           "]. Either this is a different game build, or something detoured " &
           "rid=" & $LpRid[i] & " " & LpName[i] & " before this ran and these " &
           "are its trampoline bytes. Patching anyway would corrupt code."
  outFn = fn
  result = ""

proc lpSpec(i: int): string =
  ## `Type::Method@0xRVA/<shape>!<hex prologue>` — the host's patch-by-RVA
  ## grammar. The `!` suffix is the whole point: it is what lets the host
  ## verify against its startup snapshot rather than against live memory.
  result = "UnityEngine.AssetBundle::" & LpName[i] & "@0x" &
           lpRvaHex(LpRvaTab[i]) & "/" & LpShape[i] & "!" & LpPro[i]

proc lpInstall(i: int): bool =
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = lpVerify(i, fn)
  if why.len > 0:
    warn "textures  loadprobe NOT hooking rid=" & $LpRid[i] & " " &
         LpName[i] & ": " & why
    return false
  let spec = lpSpec(i)
  # `hookTyped` = a typed PREFIX. A prefix tail-jumps into the trampoline, so
  # the return value, the stack arguments and the return address are correct by
  # construction; this handler reads none of them anyway.
  let st = hookTyped(spec, lpHandler(i))
  if st == Ok:
    info "textures  loadprobe hooked rid=" & $LpRid[i] & " " & LpName[i] &
         " @GameAssembly+0x" & lpRvaHex(LpRvaTab[i]) & " (typed PREFIX, " &
         "shape " & LpShape[i] & ", prologue verified)"
    return true
  warn "textures  loadprobe REFUSED rid=" & $LpRid[i] & " " & LpName[i] &
       " @0x" & lpRvaHex(LpRvaTab[i]) & ": " & lastError()
  result = false

proc maybeArmLoadProbe*(): bool =
  ## Called every tick. Installs exactly once, past the arm delay, and never
  ## retries a refusal — one honest line each, not a per-tick storm.
  if gLpTried:
    return false
  if not gLpEnabled:
    if gLpBlocked.len > 0:
      gLpTried = true
      warn "textures  loadprobe DISABLED: " & gLpBlocked
    return false
  if nowMs() - gLpLoadedAtMs < gLpDelayMs:
    return false
  gLpTried = true

  if not typedPatchesReady():
    warn "textures  loadprobe DISABLED: this host does not implement the " &
         "revision-4 typed patch, and the JSON patch ABI is refused for an " &
         "RVA target (no MethodInfo to describe the frame from). Nothing " &
         "installed."
    return false

  gLpInstalled = 0
  gLpRefused = 0
  for i in 0 ..< LpN:
    if not gLpWanted[i]:
      continue
    if lpInstall(i):
      gLpBound[i] = true
      gLpInstalled = gLpInstalled + 1
    else:
      gLpRefused = gLpRefused + 1

  gLpArmed = gLpInstalled > 0
  if not gLpArmed:
    warn "textures  loadprobe armed NOTHING (" & $gLpRefused &
         " target(s) refused above); the probe is a no-op"
    return false
  success "textures  loadprobe ARMED: " & $gLpInstalled & " of " &
          $(gLpInstalled + gLpRefused) & " AssetBundle target(s) counting " &
          "(prefix, count-only). rid=6 is the CONTROL and must stay 0."
  result = true

# --------------------------------------------------------------------------
# The report
# --------------------------------------------------------------------------

proc loadProbeReport*(): string =
  ## ONE line, every candidate, zeros SHOWN. "which ones did NOT fire" is half
  ## the result, so a quiet target is printed as `=0` and never omitted; a
  ## target that was asked for and refused prints `=REFUSED` and one that was
  ## never asked for prints `=-` — three states that must never read alike.
  ##
  ## Grep for:  textures  loadprobe fires
  result = "textures  loadprobe fires installed=" & $gLpInstalled &
           " refused=" & $gLpRefused & " |"
  for i in 0 ..< LpN:
    result = result & " rid" & $LpRid[i] & "/" & LpName[i] &
             "@0x" & lpRvaHex(LpRvaTab[i]) & "="
    if gLpBound[i]:
      result = result & $gLpCount[i]
    elif gLpWanted[i]:
      result = result & "REFUSED"
    else:
      result = result & "-"
  result = result & " | rid6 is the CONTROL (expect 0)"
