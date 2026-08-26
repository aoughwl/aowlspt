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
## rid=7 was the one to watch: `LoadAsset<T>(name)` and the public
## `LoadAsset(name)` both lower to `LoadAsset(string, Type)` in Unity's managed
## source, so it — not rid=6 — should have been the synchronous chokepoint.
##
## ---------------------------------------------------------------------------
## THE RAID ANSWERED, AND THE ANSWER WAS "NONE OF THEM" (fact #55)
## ---------------------------------------------------------------------------
##
## Full Factory raid, in-raid confirmed by 28 `botdiag: RegisterPlayer` events,
## eight prefixes installed, 0 refused, 0 faults. Total across all eight, in a
## raid that loads thousands of assets: **ONE** call (rid=10). The control
## stayed 0, so the counting was honest. rid=7 was 0.
##
## Post-1.0 IL2CPP Tarkov does not load its assets through Unity's public
## `AssetBundle` API at all. The TarkovTextures port premise — patch
## `AssetBundle::LoadAsset`, as that plugin did on the pre-1.0 **Mono** build
## — is dead.
##
## ---------------------------------------------------------------------------
## WHERE IT ACTUALLY GOES: BSG'S OWN ASSET LAYER
## ---------------------------------------------------------------------------
##
## The lead was a `DontDestroyOnLoad` scene root literally named `Easy Assets`.
## `tools/il2cpp_resolve.py find` on the decrypted metadata turns that into a
## whole shipped layer, in its own image `Diz.Resources.dll`:
##
##   30931 Diz.Resources.EasyAssets     Create Init Update
##   30933 Diz.Resources.EasyBundle     .ctor Load LoadingCoroutine Unload
##   30926 Diz.Resources.BundleLock     Lock Unlock
##
## and, in `Assembly-CSharp.dll`, the layer that drives it:
##
##   16622 EFT.AssetsManager.AssetsManager   GetAsset FindAsset FindAssetByMask
##                                           LoadAssetAsync x2 LoadMainAssetAsync
##                                           LoadAssetsAsync LoadBundlesAsync
##   16640 EFT.AssetsManager.BundlesManager  FindBundle UnloadBundle
##    6461 EFT.EasyAssetsExtensions          GetDefaultAsset LoadBundles x2
##                                           IsAssetLoaded
##   16607 EFT.AssetsManager.AssetBundleExtension  FixAssetName
##    8894 TextureCache                      TryGet Cache
##
## `TextureCache::TryGet` / `Cache` are the two entries in this table whose
## NAME implies a `Texture`, and a texture swap needs a Texture-typed
## chokepoint, so they are in the table for exactly that reason.
##
## TWO OFFLINE FINDINGS THAT MUST NOT BE FORGOTTEN, both measured from
## GameAssembly.dll and both capable of producing a confidently wrong hook:
##
##  1. **Property accessors are SHARED thunks.** `EasyAssets::get_System` and
##     `BundlesManager::get_DownloadingUrl` — unrelated types in different
##     images — both resolve to RVA 0x692a50, and `set_*` to 0x692a60. These
##     are IL2CPP's generic "return the field at offset N" stubs, reused across
##     hundreds of properties. Hooking one would fire for all of them and read
##     as a spectacular result. **No accessor is in this table.**
##  2. **`BundlesManager::LoadBundleAsync`@0x191b9e0 is an 8-byte tail-jump
##     thunk** (`xor r9d,r9d ; jmp rel32`, then `CC` padding). The detour needs
##     14 stealable bytes and the second instruction is a relative branch, so
##     the engine refuses it (`AOWL_INSN_RELATIVE`). It is deliberately NOT in
##     the table rather than left in to fail: its real body is at the jump
##     target, which metadata does not name, and hooking an unnamed RVA is not
##     a measurement.
##
## ---------------------------------------------------------------------------
## rids 11-14 ARE NOW INSTALLABLE, AND WHY THAT IS SAFE
## ---------------------------------------------------------------------------
##
## The previous run excluded `LoadAllAssets`/`LoadAllAssetsAsync` for a
## RIP-relative `cmp byte [rip+disp32],0` (`80 3D d32 00`) at prologue byte 10,
## inside the 14-byte steal window. Reading the engine rather than guessing at
## it (`abi/aowlspt_detour.h`) settles it:
##
##  * `aowl_insn` decodes opcode 0x80 as ModRM + imm8, and mod=0/rm=5 records
##    `ripDisp` — the byte offset of the displacement — rather than refusing.
##  * `aowl_copy_relocated` rewrites that displacement by exactly the distance
##    the instruction moved, so the copied `cmp` still reads the same byte.
##  * If the trampoline ever landed more than 2 GB away the new displacement
##    would not fit in 32 bits, and the copier returns -1 and the hook is
##    REFUSED. The failure mode is a refusal, not a corrupt relocation.
##
## So rids 11-14 are installable and were merely UNMEASURED, not unsafe. They
## are selectable as `ab11`..`ab14` (or the whole `ab` group).

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
  LpN = 37

  ## Selector tag. UNIQUE across the whole table -- rids are per-IMAGE and
  ## DO collide (AssetBundle rid=15 vs EasyAssets rid=15), so the tag and
  ## not the bare rid is the identity. A bare number in `probeTargets` still
  ## resolves inside the AssetBundle group only, for compatibility with the
  ## measurement that produced this table.
  LpTag: array[LpN, string] = [
    "ab6",
    "ab7",
    "ab8",
    "ab9",
    "ab10",
    "ab11",
    "ab12",
    "ab13",
    "ab14",
    "ab15",
    "ab18",
    "ab19",
    "eb41",
    "eb42",
    "eb43",
    "eb44",
    "ea17",
    "ea18",
    "ea19",
    "am100577",
    "am100578",
    "am100579",
    "am100582",
    "am100584",
    "am100585",
    "am100586",
    "am100587",
    "am100588",
    "bm100686",
    "bm100687",
    "ex40812",
    "ex40823",
    "ex40824",
    "ex40825",
    "tc56889",
    "tc56890",
    "abx100570"]

  ## Group selector: ab eb ea am bm ex tc abx. Also 'bsg' (everything BSG,
  ## plus the ab6 control) and 'all'.
  LpGroup: array[LpN, string] = [
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "ab",
    "eb",
    "eb",
    "eb",
    "eb",
    "ea",
    "ea",
    "ea",
    "am",
    "am",
    "am",
    "am",
    "am",
    "am",
    "am",
    "am",
    "am",
    "bm",
    "bm",
    "ex",
    "ex",
    "ex",
    "ex",
    "tc",
    "tc",
    "abx"]

  LpRid: array[LpN, int] = [
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    18,
    19,
    41,
    42,
    43,
    44,
    17,
    18,
    19,
    100577,
    100578,
    100579,
    100582,
    100584,
    100585,
    100586,
    100587,
    100588,
    100686,
    100687,
    40812,
    40823,
    40824,
    40825,
    56889,
    56890,
    100570]

  LpType: array[LpN, string] = [
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "UnityEngine.AssetBundle",
    "Diz.Resources.EasyBundle",
    "Diz.Resources.EasyBundle",
    "Diz.Resources.EasyBundle",
    "Diz.Resources.EasyBundle",
    "Diz.Resources.EasyAssets",
    "Diz.Resources.EasyAssets",
    "Diz.Resources.EasyAssets",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.AssetsManager",
    "EFT.AssetsManager.BundlesManager",
    "EFT.AssetsManager.BundlesManager",
    "EFT.EasyAssetsExtensions",
    "EFT.EasyAssetsExtensions",
    "EFT.EasyAssetsExtensions",
    "EFT.EasyAssetsExtensions",
    "TextureCache",
    "TextureCache",
    "EFT.AssetsManager.AssetBundleExtension"]

  LpName: array[LpN, string] = [
    "LoadAsset",
    "LoadAsset",
    "LoadAsset_Internal",
    "LoadAssetAsync",
    "LoadAssetAsync",
    "LoadAllAssets",
    "LoadAllAssets",
    "LoadAllAssetsAsync",
    "LoadAllAssetsAsync",
    "LoadAssetAsync_Internal",
    "LoadAssetWithSubAssets_Internal",
    "LoadAssetWithSubAssetsAsync_Internal",
    ".ctor",
    "Load",
    "LoadingCoroutine",
    "Unload",
    "Create",
    "Init",
    "Update",
    "GetAssetName",
    "FindAsset",
    "FindAssetByMask",
    "GetAsset",
    "LoadAssetAsync",
    "LoadAssetAsync",
    "LoadMainAssetAsync",
    "LoadAssetsAsync",
    "LoadBundlesAsync",
    "UnloadBundle",
    "FindBundle",
    "GetDefaultAsset",
    "LoadBundles",
    "LoadBundles",
    "IsAssetLoaded",
    "TryGet",
    "Cache",
    "FixAssetName"]

  LpRvaTab: array[LpN, uint32] = [
    0x5250100'u32,
    0x5250340'u32,
    0x52504e0'u32,
    0x5250550'u32,
    0x5250630'u32,
    0x52507d0'u32,
    0x5250980'u32,
    0x5250a90'u32,
    0x5250c40'u32,
    0x5250d50'u32,
    0x5250e70'u32,
    0x5250ee0'u32,
    0x2772940'u32,
    0x2772cc0'u32,
    0x2773020'u32,
    0x27731e0'u32,
    0x2770c00'u32,
    0x2770fb0'u32,
    0x2771370'u32,
    0x19112d0'u32,
    0x19114c0'u32,
    0x1911530'u32,
    0x19117e0'u32,
    0x1911a60'u32,
    0x1911b20'u32,
    0x1911bd0'u32,
    0x1911c50'u32,
    0x1911cd0'u32,
    0x191b9f0'u32,
    0x191bc30'u32,
    0x253ef00'u32,
    0x253fce0'u32,
    0x253ff00'u32,
    0x253ff70'u32,
    0xbde7e0'u32,
    0xbde910'u32,
    0x1910c40'u32]

  ## DECLARED frame shape. INFERRED from the method NAME, never measured --
  ## there is no MethodInfo behind an RVA. It is INERT on a prefix: read
  ## `aowl_thunk_common` in abi/aowlspt_detour.h -- the prefix path saves
  ## RCX/RDX/R8/R9 + XMM0-3, calls the dispatcher, restores them and
  ## tail-jumps to the trampoline without ever consulting `frameKinds` or
  ## `retKind`. It exists only to satisfy the spec grammar, which REFUSES an
  ## RVA patch that declares no shape. Do NOT reuse any of these on a
  ## postfix.
  LpShape: array[LpN, string] = [
    "io>o",
    "ioo>o",
    "ioo>o",
    "io>o",
    "ioo>o",
    "i>o",
    "io>o",
    "i>o",
    "io>o",
    "ioo>o",
    "ioo>o",
    "ioo>o",
    "ioo>x",
    "i>o",
    "i>o",
    "i>x",
    "sooo>o",
    "iooo>o",
    "i>x",
    "ioo>o",
    "ioo>o",
    "ioo>o",
    "ioo>o",
    "ioo>o",
    "ioo>o",
    "io>o",
    "ioo>o",
    "iooo>o",
    "ioo>x",
    "ioo>o",
    "so>o",
    "sooo>o",
    "so>o",
    "soo>i",
    "sooo>i",
    "sooo>x",
    "soo>o"]

  ## The 16 bytes each function begins with in D:/Games/Tarkov/GameAssembly.dll
  ## on build 1.1.0.1.46777, read at the file offset the PE section table maps
  ## each RVA to. Every one lands in the `il2cpp` section.
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
    "48895C24084889742410574883EC2048",
    "48895C240848896C2410488974241848",
    "48895C2410574881EC90000000488BD9",
    "40534881EC90000000803D332C950400",
    "40534883EC40803D772A950400488BD9",
    "48895C2408488974241048897C24184C",
    "48895C2408488974241048897C24184C",
    "40534883EC20803DDC48950400488BD9",
    "48895C2410564883EC30803DDADC7A05",
    "48895C2410574883EC20803DEBDA7A05",
    "48895C24184889742420574883EC2080",
    "48895C2420564883EC30803DCDD77A05",
    "48895C24084889742410574883EC3048",
    "48895C24084889742410574883EC3080",
    "48895C2408574883EC30803DDFD37A05",
    "48895C2408574883EC30803D60D37A05",
    "48895C240848896C2410488974241857",
    "48895C24104889742418574883EC2080",
    "48895C2410574883EC20803DBD337A05",
    "40534883EC20803DB741B80400488BD9",
    "48895C24084889742410574883EC4080",
    "40534883EC20803DC131B80400488BD9",
    "48895C2408574883EC20803D4E31B804",
    "48895C240848896C2410488974241848",
    "48895C241048896C2418488974242041",
    "405355574883EC20803D6AE37A050048"]

var gLpCount: array[LpN, int64] = [
  0'i64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

var gLpWanted: array[LpN, bool] = [
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false]
var gLpBound: array[LpN, bool] = [
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false, false, false, false,
  false, false, false, false, false]

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
proc lpFire12(f: PatchFrame): TypedResult =
  gLpCount[12] = gLpCount[12] + 1
  frameContinue()
proc lpFire13(f: PatchFrame): TypedResult =
  gLpCount[13] = gLpCount[13] + 1
  frameContinue()
proc lpFire14(f: PatchFrame): TypedResult =
  gLpCount[14] = gLpCount[14] + 1
  frameContinue()
proc lpFire15(f: PatchFrame): TypedResult =
  gLpCount[15] = gLpCount[15] + 1
  frameContinue()
proc lpFire16(f: PatchFrame): TypedResult =
  gLpCount[16] = gLpCount[16] + 1
  frameContinue()
proc lpFire17(f: PatchFrame): TypedResult =
  gLpCount[17] = gLpCount[17] + 1
  frameContinue()
proc lpFire18(f: PatchFrame): TypedResult =
  gLpCount[18] = gLpCount[18] + 1
  frameContinue()
proc lpFire19(f: PatchFrame): TypedResult =
  gLpCount[19] = gLpCount[19] + 1
  frameContinue()
proc lpFire20(f: PatchFrame): TypedResult =
  gLpCount[20] = gLpCount[20] + 1
  frameContinue()
proc lpFire21(f: PatchFrame): TypedResult =
  gLpCount[21] = gLpCount[21] + 1
  frameContinue()
proc lpFire22(f: PatchFrame): TypedResult =
  gLpCount[22] = gLpCount[22] + 1
  frameContinue()
proc lpFire23(f: PatchFrame): TypedResult =
  gLpCount[23] = gLpCount[23] + 1
  frameContinue()
proc lpFire24(f: PatchFrame): TypedResult =
  gLpCount[24] = gLpCount[24] + 1
  frameContinue()
proc lpFire25(f: PatchFrame): TypedResult =
  gLpCount[25] = gLpCount[25] + 1
  frameContinue()
proc lpFire26(f: PatchFrame): TypedResult =
  gLpCount[26] = gLpCount[26] + 1
  frameContinue()
proc lpFire27(f: PatchFrame): TypedResult =
  gLpCount[27] = gLpCount[27] + 1
  frameContinue()
proc lpFire28(f: PatchFrame): TypedResult =
  gLpCount[28] = gLpCount[28] + 1
  frameContinue()
proc lpFire29(f: PatchFrame): TypedResult =
  gLpCount[29] = gLpCount[29] + 1
  frameContinue()
proc lpFire30(f: PatchFrame): TypedResult =
  gLpCount[30] = gLpCount[30] + 1
  frameContinue()
proc lpFire31(f: PatchFrame): TypedResult =
  gLpCount[31] = gLpCount[31] + 1
  frameContinue()
proc lpFire32(f: PatchFrame): TypedResult =
  gLpCount[32] = gLpCount[32] + 1
  frameContinue()
proc lpFire33(f: PatchFrame): TypedResult =
  gLpCount[33] = gLpCount[33] + 1
  frameContinue()
proc lpFire34(f: PatchFrame): TypedResult =
  gLpCount[34] = gLpCount[34] + 1
  frameContinue()
proc lpFire35(f: PatchFrame): TypedResult =
  gLpCount[35] = gLpCount[35] + 1
  frameContinue()
proc lpFire36(f: PatchFrame): TypedResult =
  gLpCount[36] = gLpCount[36] + 1
  frameContinue()

proc lpHandler(i: int): TypedPatchHandler =
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
  of 11: lpFire11
  of 12: lpFire12
  of 13: lpFire13
  of 14: lpFire14
  of 15: lpFire15
  of 16: lpFire16
  of 17: lpFire17
  of 18: lpFire18
  of 19: lpFire19
  of 20: lpFire20
  of 21: lpFire21
  of 22: lpFire22
  of 23: lpFire23
  of 24: lpFire24
  of 25: lpFire25
  of 26: lpFire26
  of 27: lpFire27
  of 28: lpFire28
  of 29: lpFire29
  of 30: lpFire30
  of 31: lpFire31
  of 32: lpFire32
  of 33: lpFire33
  of 34: lpFire34
  of 35: lpFire35
  else: lpFire36


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

proc lpSelectGroup(g: string): bool =
  ## Selects every entry whose group is `g`. `bsg` means "BSG's own asset
  ## layer" -- everything that is NOT UnityEngine.AssetBundle -- PLUS ab6, so
  ## a bsg run still carries the control that proves the counting is honest.
  result = false
  for i in 0 ..< LpN:
    if LpGroup[i] == g or (g == "bsg" and
        (LpGroup[i] != "ab" or LpTag[i] == "ab6")):
      gLpWanted[i] = true
      result = true

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
    # A bounded parse: at most LpN + 8 fields.
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
      # 1. A TAG -- the only unambiguous form, because rids are per-IMAGE and
      #    collide across the eight types in this table.
      for i in 0 ..< LpN:
        if f == LpTag[i]:
          gLpWanted[i] = true
          found = true
      # 2. A GROUP name.
      if not found:
        if lpSelectGroup(f):
          found = true
      # 3. A BARE NUMBER. Resolved ONLY inside the UnityEngine.AssetBundle
      #    group, so the strings that produced the fact-#55 measurement
      #    ("6,7,8,...") still mean exactly what they meant then. It is NOT
      #    extended to the other groups: rid=15 is both AssetBundle
      #    LoadAssetAsync_Internal and EasyAssets get_System, and a selector
      #    that quietly picked one would be the worst kind of wrong.
      if not found:
        for i in 0 ..< LpN:
          if LpGroup[i] == "ab" and f == $LpRid[i]:
            gLpWanted[i] = true
            found = true
      if not found:
        warn "textures  loadprobe: probeTargets names '" & f &
             "', which is neither a tag, a group, nor an AssetBundle rid; " &
             "IGNORED. Groups: ab eb ea am bm ex tc abx bsg all. Tags are " &
             "listed in the table in mods/textures/loadprobe.nim; a BARE " &
             "number resolves only inside the ab group."

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
           LpTag[i] & " " & LpType[i] & "::" & LpName[i] &
           " before this ran and these " &
           "are its trampoline bytes. Patching anyway would corrupt code."
  outFn = fn
  result = ""

proc lpSpec(i: int): string =
  ## `Type::Method@0xRVA/<shape>!<hex prologue>` — the host's patch-by-RVA
  ## grammar. The `!` suffix is the whole point: it is what lets the host
  ## verify against its startup snapshot rather than against live memory.
  result = LpType[i] & "::" & LpName[i] & "@0x" &
           lpRvaHex(LpRvaTab[i]) & "/" & LpShape[i] & "!" & LpPro[i]

proc lpInstall(i: int): bool =
  var fn: Il2CppPtr = cast[Il2CppPtr](0)
  let why = lpVerify(i, fn)
  if why.len > 0:
    warn "textures  loadprobe NOT hooking " & LpTag[i] & " " & LpType[i] &
         "::" & LpName[i] & ": " & why
    return false
  let spec = lpSpec(i)
  # `hookTyped` = a typed PREFIX. A prefix tail-jumps into the trampoline, so
  # the return value, the stack arguments and the return address are correct by
  # construction; this handler reads none of them anyway.
  let st = hookTyped(spec, lpHandler(i))
  if st == Ok:
    info "textures  loadprobe hooked " & LpTag[i] & " " & LpType[i] &
         "::" & LpName[i] &
         " @GameAssembly+0x" & lpRvaHex(LpRvaTab[i]) & " (typed PREFIX, " &
         "shape " & LpShape[i] & ", prologue verified)"
    return true
  warn "textures  loadprobe REFUSED " & LpTag[i] & " " & LpType[i] &
       "::" & LpName[i] &
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
          $(gLpInstalled + gLpRefused) & " target(s) counting (prefix, " &
          "count-only). ab6 is the CONTROL and must stay 0."
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
    result = result & " " & LpTag[i] & "="
    if gLpBound[i]:
      result = result & $gLpCount[i]
    elif gLpWanted[i]:
      result = result & "REFUSED"
    else:
      result = result & "-"
  result = result & " | ab6 (AssetBundle::LoadAsset@0x5250100) is the " &
    "CONTROL and MUST stay 0; a non-zero ab6 invalidates the whole run. " &
    "'-' = never asked for, REFUSED = asked for and declined above. Tag -> " &
    "type/method/RVA is printed once per target by the 'hooked' lines at arm."
