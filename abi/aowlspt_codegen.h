/* aowlspt_codegen.h -- resolve a compiled method address from IL2CPP's OWN
 * per-assembly code table, at run time, when `MethodInfo.methodPointer` is null.
 *
 * ## The measured problem this exists for
 *
 * On build 1.1.0.1.46777 `MethodInfo.methodPointer` (offset 0) reads NULL for
 * many methods that resolve perfectly by name. `il2cpp_class_from_name` and
 * `il2cpp_class_get_method_from_name` both SUCCEED; only the code pointer field
 * is empty. Measured live 2026-08-23 with the textures mod in `swapMode=probe`:
 *
 *     warn textures  NOT hooking UnityEngine.AssetBundle::LoadAsset:
 *                    methodPointer is null - the host would refuse this too
 *
 * and the same class of failure in the host's own startup lines ("no usable
 * code pointer for EFT.TarkovApplication::Update", GameWorld::Update,
 * CanvasUpdateRegistry::PerformUpdate, Time::get_deltaTime).
 *
 * The host's only fallback was `scanMethodPointer` -- scan the first nine
 * qwords of the MethodInfo for an executable pointer in the il2cpp section.
 * That is a guess. It is flag-gated and its own log says it "may crash if it is
 * a wrong-but-real function". This header replaces the guess with the actual
 * mechanism IL2CPP uses.
 *
 * ## The mechanism (ground truth: tools/il2cpp_resolve.py)
 *
 * IL2CPP stores compiled method addresses in a PER-ASSEMBLY table,
 * `Il2CppCodeGenModule.methodPointers`, indexed by `(token & 0xFFFFFF) - 1`.
 * A token's RID is per-IMAGE, so the table that must be used is the one
 * belonging to the image the method's DECLARING TYPE lives in. Using
 * Assembly-CSharp.dll's table for everything is a documented past bug in that
 * resolver (it misses BattlEye.BEClient, which is in
 * Assembly-CSharp-firstpass.dll, table base 0x186BF1380).
 *
 * So the chain, all of it through the runtime's OWN exported C API except the
 * last hop:
 *
 *   MethodInfo* -> il2cpp_method_get_class   -> Il2CppClass*
 *               -> il2cpp_class_get_image    -> Il2CppImage*
 *               -> il2cpp_image_get_name     -> "UnityEngine.AssetBundleModule.dll"
 *               -> this table, matched BY NAME -> methodPointers, count
 *   il2cpp_method_get_token(m) & 0xFFFFFF = rid
 *   methodPointers[rid - 1] = the compiled function
 *
 * Both `il2cpp_class_get_image` and `il2cpp_method_get_token` are confirmed
 * exported by this GameAssembly.dll (checked against the PE export directory:
 * 386 exports, both present). That matters: it means this walk needs NO guessed
 * struct offset for MethodInfo, Il2CppClass or Il2CppImage. The only assumed
 * layout is `Il2CppCodeGenModule` itself, and that one is measured -- it is the
 * same layout `tools/il2cpp_resolve.py` reads, and that resolver reproduces all
 * five BE-bypass RVAs in `aowlspt_beclient.h` and every VA in `docs/SETTINGS.md`
 * byte-for-byte.
 *
 *     Il2CppCodeGenModule:  +0x00 const char* moduleName
 *                           +0x08 uint32_t    methodPointerCount
 *                           +0x10 void**      methodPointers
 *
 * ## Where the table is
 *
 * `Il2CppCodeRegistration` in `.rdata` holds `codeGenModulesCount` immediately
 * followed by `codeGenModules`. Located offline in GameAssembly.dll:
 *
 *     RVA 0x586EA78  uint32  codeGenModulesCount = 146 (0x92)
 *     RVA 0x586EA80  void**  codeGenModules      -> VA 0x186BDC190 (RVA 0x6BDC190)
 *
 * The count and the array pointer are READ from that pair rather than hardcoded
 * as an array address, and then the array is validated by walking it: 146 of
 * 146 entries resolve to a readable module-name string, 145 ending in ".dll"
 * plus the one `__Generated` module. On any other build that validation fails
 * and every lookup here refuses.
 *
 * ## Static cross-check (offline, against tools/il2cpp_resolve.py)
 *
 * Walking the array exactly as the code below does, versus the resolver's own
 * independent scan:
 *
 *   UnityEngine.AssetBundle::LoadAsset  rid 6     -> 0x5250100   MATCH
 *   UnityEngine.AssetBundle::LoadAsset  rid 7     -> 0x5250340   MATCH
 *   EFT.TarkovApplication::Update       rid 50571 -> 0x977B10    MATCH
 *   EFT.GameWorld::Update               rid 39762 -> 0x2500A20   MATCH
 *   UnityEngine.UI.CanvasUpdateRegistry::PerformUpdate rid 37 -> 0x539B340 MATCH
 *   UnityEngine.Time::get_deltaTime     rid 3094  -> 0x7E99B0    MATCH
 *   BattlEye.BEClient::Update           rid 433   -> 0x669390    MATCH
 *
 * The last is the strongest: 0x669390 is an INDEPENDENTLY known-good RVA out of
 * `aowlspt_beclient.h`, and it lives in a different module than the rest, so it
 * only comes out right if the per-image table selection is right.
 *
 * ## Safety
 *
 * Nothing here calls into the game and nothing here writes. Every hop is
 * `aowl_is_readable` (a VirtualQuery, not a faulting dereference), so there is
 * no SEH guard in this file at all and therefore nothing that could disarm an
 * outer `aowl_p_p_seh`. Every loop is capped. A returned pointer must be inside
 * the `il2cpp` PE section AND on an executable page, so a data pointer, a
 * vtable slot or a runtime stub cannot come back out. Every refusal sets a
 * reason code the host logs by name -- there is no silent decline.
 *
 * ## The caveat the host must keep printing
 *
 * `aowlhost.nim`'s `bindMainDrain` records that a STATIC RVA out of this same
 * table, byte-verified, was bound on the live client and the drain never fired
 * (the game crashed seconds later). The later note at the static-RVA block
 * walks that back -- "the address is now KNOWN correct ... the earlier crash on
 * this exact target is unexplained". Both notes are in the tree and they do not
 * agree, and that disagreement has NOT been re-tested. That is why the host
 * gates this behind a default-OFF flag and why `aowl_codegen_agreement_*`
 * exists: when `methodPointer` IS readable the host compares the two and logs
 * whether they agree, so the live client -- not this comment -- settles it.
 *
 * ## ASLR: there is no 0x180000000 in this file, on purpose
 *
 * GameAssembly.dll is RELOCATED -- it does not load at its preferred base
 * 0x180000000. Measured live 2026-08-23: module base 0x7FFDB73F0000 (fact #29).
 * Reads against un-rebased static VAs all came back "not readable"; rebased,
 * every one succeeded. So a hardcoded preferred base here would be unreadable
 * at best and a wrong-but-mapped function at worst.
 *
 * This walk cannot make that mistake, by construction:
 *   - the ONE static address it uses, AOWL_CG_CODEREG_RVA, is an RVA added to
 *     the LIVE base from GetModuleHandleA("GameAssembly.dll");
 *   - everything after that -- the codeGenModules array pointer, each module
 *     struct pointer, each moduleName, the methodPointers base and every slot
 *     in it -- is a pointer READ OUT OF RELOCATED MEMORY. The loader has
 *     already applied the relocations, so those are live addresses and there
 *     is nothing left to rebase.
 * grep this file for 0x180000000: the only hit is the line below, in prose.
 *
 * Corollary, also worth stating because it is easy to get backwards, and it was
 * got backwards once: `aowl_il2cpp_rva_of` in `aowlspt_bridge.h` returns
 * `p - GetModuleHandleA("GameAssembly.dll")`, i.e. a MODULE-relative RVA, NOT
 * one relative to the il2cpp section start (0x628000). That is the same space
 * `tools/il2cpp_resolve.py` prints, which is why the log lines this file's
 * callers emit can be pasted straight into a comparison with it. The live
 * inspector's `call`/fault RVAs are the OTHER space -- section-relative -- and
 * the two are not interchangeable, though both look reasonable in a log.
 *
 * ## Live confirmation of the whole chain (fact #28)
 *
 * Hand-walked with the live inspector, module base 0x7FFDB73F0000:
 *   UnityEngine.AssetBundleModule.dll methodPointers = static 0x187080AD0,
 *   count 25, live 0x7FFDBE470AD0.
 *     [0] live 0x7FFDBC63FF90 = base+0x524FF90  .ctor      rid 1
 *     [5] live 0x7FFDBC640100 = base+0x5250100  LoadAsset  rid 6
 *     [6] live 0x7FFDBC640340 = base+0x5250340  LoadAsset  rid 7
 *   and the bytes at base+0x5250100 read 48 89 5C 24 08 48 89 74 -- the
 *   expected LoadAsset prologue. Those are the same table base, the same count
 *   and the same two RIDs this file's offline cross-check produced.
 *
 * RVAs are for imagebase 0x180000000 and build 1.1.0.1.46777.
 */

#ifndef AOWLSPT_CODEGEN_H
#define AOWLSPT_CODEGEN_H

#include <windows.h>
#include <stdint.h>

/* aowl_is_readable / aowl_is_code_pointer */
#include "aowlspt_shim.h"
/* aowl_in_il2cpp_section / aowl_il2cpp_rva_of */
#include "aowlspt_bridge.h"

/* `Il2CppCodeRegistration.codeGenModulesCount` -- the array pointer follows it.
 * Found offline: the only reference to the module array in the image, and the
 * qword before it reads 0x92 = 146, the module count. */
#define AOWL_CG_CODEREG_RVA   0x586EA78u

/* Field offsets inside Il2CppCodeGenModule. Measured, not guessed -- see the
 * header comment; this is the layout tools/il2cpp_resolve.py reads. */
#define AOWL_CG_MOD_NAME_OFF   0x00
#define AOWL_CG_MOD_COUNT_OFF  0x08
#define AOWL_CG_MOD_PTRS_OFF   0x10

/* Caps. Nothing here loops without one. */
#define AOWL_CG_MAX_MODULES    1024
#define AOWL_CG_MAX_NAME       192
#define AOWL_CG_MIN_VALID_MODS 64

/* Reason codes. Every refusal path sets exactly one, and the host prints the
 * matching sentence from `aowl_codegen_reason_text`. */
enum {
    AOWL_CG_OK = 0,
    AOWL_CG_NO_MODULE_HANDLE,   /* GameAssembly.dll not loaded              */
    AOWL_CG_REG_UNREADABLE,     /* the code-registration pair did not read  */
    AOWL_CG_BAD_COUNT,          /* module count outside a sane range        */
    AOWL_CG_ARRAY_UNREADABLE,   /* the module pointer array did not read    */
    AOWL_CG_TOO_FEW_MODULES,    /* array read but did not look like modules */
    AOWL_CG_NO_IMAGE_NAME,      /* caller had no image name to match on     */
    AOWL_CG_MODULE_NOT_FOUND,   /* no codeGenModule with that name          */
    AOWL_CG_NO_METHOD_TABLE,    /* the module has no methodPointers table   */
    AOWL_CG_RID_RANGE,          /* token RID outside that module's table    */
    AOWL_CG_SLOT_UNREADABLE,    /* the table slot itself did not read       */
    AOWL_CG_SLOT_NULL,          /* the table slot holds NULL                */
    AOWL_CG_NOT_IL2CPP_SECTION, /* resolved, but not in the il2cpp section  */
    AOWL_CG_NOT_EXECUTABLE      /* resolved, in section, but not executable */
};

static int32_t aowl_codegen_last_reason = AOWL_CG_OK;

static const char* aowl_codegen_reason_text(int32_t r) {
    switch (r) {
        case AOWL_CG_OK:                return "ok";
        case AOWL_CG_NO_MODULE_HANDLE:  return "GameAssembly.dll is not loaded";
        case AOWL_CG_REG_UNREADABLE:    return "the Il2CppCodeRegistration module pair at RVA 0x586EA78 is not readable (wrong build?)";
        case AOWL_CG_BAD_COUNT:         return "codeGenModulesCount is outside a sane range (wrong build?)";
        case AOWL_CG_ARRAY_UNREADABLE:  return "the codeGenModules pointer array is not readable";
        case AOWL_CG_TOO_FEW_MODULES:   return "the codeGenModules array did not validate as module structs (wrong build?)";
        case AOWL_CG_NO_IMAGE_NAME:     return "no image name for the declaring type (il2cpp_class_get_image or il2cpp_image_get_name unavailable)";
        case AOWL_CG_MODULE_NOT_FOUND:  return "no Il2CppCodeGenModule matches that image name";
        case AOWL_CG_NO_METHOD_TABLE:   return "that module has an empty methodPointers table";
        case AOWL_CG_RID_RANGE:         return "the method token RID is outside that module's methodPointers table";
        case AOWL_CG_SLOT_UNREADABLE:   return "the methodPointers slot is not readable";
        case AOWL_CG_SLOT_NULL:         return "the methodPointers slot holds NULL (the method has no compiled body in this build)";
        case AOWL_CG_NOT_IL2CPP_SECTION:return "the resolved address is not in the il2cpp PE section";
        case AOWL_CG_NOT_EXECUTABLE:    return "the resolved address is not on an executable page";
        default:                        return "unknown";
    }
}

/* Resolution state. The distinction between 0 and 2 is the whole point:
 *
 *   -1  never attempted
 *    0  attempted and failed RETRYABLY -- GameAssembly.dll was not mapped yet.
 *       This is NOT a fact about the build, so it is deliberately NOT latched.
 *    1  SUCCESS. Latched; the table does not move for the life of the process.
 *    2  attempted with GameAssembly.dll PRESENT and the table genuinely did not
 *       validate. Latched, because that IS a fact about the build.
 *
 * Measured 2026-08-23, and the reason state 0 exists at all: the host calls in
 * at DLL-attach, at 0:00:00.031, and IL2CPP does not come up until ~0:00:01.0.
 * `GetModuleHandleA` correctly returns NULL for that first second. The previous
 * version cached that as a permanent verdict and then reported it, five seconds
 * later, as "the table did not validate on this build" -- a confidently wrong
 * diagnostic about a build, produced before the build's code was even mapped.
 * A negative computed before the module exists is not evidence of anything. */
static int32_t  aowl_cg_state = -1;
static int32_t  aowl_cg_latched_reason = AOWL_CG_OK;
static int32_t  aowl_cg_attempts = 0;       /* total calls that did real work  */
static int32_t  aowl_cg_waits = 0;          /* those that found no module yet  */
static void**   aowl_cg_modules = NULL;
static uint32_t aowl_cg_module_count = 0;
static int32_t  aowl_cg_valid_names = 0;

/* Diagnostic counters for the agreement check the host runs when BOTH
 * `methodPointer` and this walk produce an address. Read by the host and
 * logged; they are the only way to settle, on the live client, whether this
 * build's table holds the pointer the game actually calls. */
static int32_t aowl_codegen_agreement_same = 0;
static int32_t aowl_codegen_agreement_diff = 0;

/* Byte-compare two NUL-terminated strings, bounded, re-checking readability
 * whenever the read crosses a page. `a` comes from the module struct and is not
 * trusted; `b` is ours. */
static int32_t aowl_cg_streq(const char* a, const char* b) {
    int32_t i;
    if (!a || !b) return 0;
    for (i = 0; i < AOWL_CG_MAX_NAME; ++i) {
        const char* p = a + i;
        if (((uintptr_t)p & 0xFFFu) == 0u || i == 0) {
            if (!aowl_is_readable((void*)p, 1)) return 0;
        }
        if (*p != b[i]) return 0;
        if (*p == '\0') return 1;
    }
    return 0;   /* ran past the cap without a terminator: not a name */
}

/* Whether a module-name pointer reads as a plausible assembly name. Used only
 * to VALIDATE the array, never to select from it. */
static int32_t aowl_cg_name_plausible(const char* a) {
    int32_t i;
    if (!a) return 0;
    for (i = 0; i < AOWL_CG_MAX_NAME; ++i) {
        const char* p = a + i;
        if (((uintptr_t)p & 0xFFFu) == 0u || i == 0) {
            if (!aowl_is_readable((void*)p, 1)) return 0;
        }
        if (*p == '\0') return i > 0 ? 1 : 0;
        if (*p < 0x20 || (unsigned char)*p > 0x7E) return 0;
    }
    return 0;
}

/* Locate and validate the codeGenModules array. Idempotent; safe to call from
 * any thread; touches nothing but its own statics. */
static int32_t aowl_codegen_init(void) {
    HMODULE ga;
    uintptr_t base;
    void* reg;
    uint32_t count;
    void** arr;
    uint32_t i;
    int32_t ok;

    /* Latched outcomes -- both of these ARE facts, so they short-circuit. */
    if (aowl_cg_state == 1) {
        aowl_codegen_last_reason = AOWL_CG_OK;
        return 1;
    }
    if (aowl_cg_state == 2) {
        aowl_codegen_last_reason = aowl_cg_latched_reason;
        return 0;
    }

    /* state -1 (never tried) or 0 (module was not up last time): try again.
     * Every call retries until it either succeeds or gets a real answer with
     * the module present, so a caller that runs before il2cpp_init is simply
     * early, not permanently poisoned. */
    ++aowl_cg_attempts;

    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) {
        ++aowl_cg_waits;
        aowl_cg_state = 0;                  /* retryable -- NOT latched */
        aowl_codegen_last_reason = AOWL_CG_NO_MODULE_HANDLE;
        return 0;
    }
    base = (uintptr_t)ga;

    /* From here the module IS mapped, so every failure below is a real finding
     * about this build and every one of them latches at state 2. */
    reg = (void*)(base + AOWL_CG_CODEREG_RVA);
    if (!aowl_is_readable(reg, 16)) {
        aowl_cg_state = 2;
        aowl_cg_latched_reason = AOWL_CG_REG_UNREADABLE;
        aowl_codegen_last_reason = AOWL_CG_REG_UNREADABLE; return 0;
    }
    count = *(uint32_t*)reg;
    arr   = *(void***)((char*)reg + 8);

    if (count < 8u || count > (uint32_t)AOWL_CG_MAX_MODULES) {
        aowl_cg_state = 2;
        aowl_cg_latched_reason = AOWL_CG_BAD_COUNT;
        aowl_codegen_last_reason = AOWL_CG_BAD_COUNT; return 0;
    }
    if (!arr || !aowl_is_readable((void*)arr, (int32_t)(count * 8u))) {
        aowl_cg_state = 2;
        aowl_cg_latched_reason = AOWL_CG_ARRAY_UNREADABLE;
        aowl_codegen_last_reason = AOWL_CG_ARRAY_UNREADABLE; return 0;
    }

    ok = 0;
    for (i = 0; i < count && i < (uint32_t)AOWL_CG_MAX_MODULES; ++i) {
        void* mod = arr[i];
        const char* nm;
        if (!mod || !aowl_is_readable(mod, 24)) continue;
        nm = *(const char**)((char*)mod + AOWL_CG_MOD_NAME_OFF);
        if (aowl_cg_name_plausible(nm)) ++ok;
    }
    aowl_cg_valid_names = ok;
    if (ok < AOWL_CG_MIN_VALID_MODS) {
        aowl_cg_state = 2;
        aowl_cg_latched_reason = AOWL_CG_TOO_FEW_MODULES;
        aowl_codegen_last_reason = AOWL_CG_TOO_FEW_MODULES; return 0;
    }

    aowl_cg_modules = arr;
    aowl_cg_module_count = count;
    aowl_codegen_last_reason = AOWL_CG_OK;
    aowl_cg_state = 1;
    return 1;
}

static int32_t aowl_codegen_ready(void)        { return aowl_codegen_init(); }
static int32_t aowl_codegen_modules(void)      { return (int32_t)aowl_cg_module_count; }
static int32_t aowl_codegen_valid_names(void)  { return aowl_cg_valid_names; }
static int32_t aowl_codegen_reason(void)       { return aowl_codegen_last_reason; }
static int32_t aowl_codegen_attempts(void)     { return aowl_cg_attempts; }
static int32_t aowl_codegen_waits(void)        { return aowl_cg_waits; }

/* Whether the last refusal was "the runtime is not up yet, ask again" rather
 * than "this build's table is bad". The host prints a DIFFERENT sentence for
 * each, because conflating them is what produced the wrong diagnostic once
 * already: at 0:00:00.031 the honest answer is "too early", and saying
 * "the table did not validate on this build" instead is an assertion about
 * something that has not been looked at. */
static int32_t aowl_codegen_waiting(void) {
    return (aowl_cg_state <= 0 &&
            aowl_codegen_last_reason == AOWL_CG_NO_MODULE_HANDLE) ? 1 : 0;
}
static const char* aowl_codegen_reason_str(void) {
    return aowl_codegen_reason_text(aowl_codegen_last_reason);
}

/* The whole point. `imageName` is what `il2cpp_image_get_name` returned for the
 * method's declaring class; `token` is `il2cpp_method_get_token`.
 *
 * Returns the compiled function, or NULL with `aowl_codegen_last_reason` set to
 * exactly which hop refused. */
static void* aowl_codegen_lookup(const char* imageName, uint32_t token) {
    uint32_t rid, i;

    if (!aowl_codegen_init()) return NULL;
    if (!imageName || !imageName[0]) {
        aowl_codegen_last_reason = AOWL_CG_NO_IMAGE_NAME; return NULL;
    }

    rid = token & 0xFFFFFFu;

    for (i = 0; i < aowl_cg_module_count && i < (uint32_t)AOWL_CG_MAX_MODULES; ++i) {
        void* mod = aowl_cg_modules[i];
        const char* nm;
        uint32_t mcount;
        void** ptrs;
        void* slot;
        void* fn;

        if (!mod || !aowl_is_readable(mod, 24)) continue;
        nm = *(const char**)((char*)mod + AOWL_CG_MOD_NAME_OFF);
        if (!aowl_cg_streq(nm, imageName)) continue;

        /* matched -- from here every failure is terminal and named */
        mcount = *(uint32_t*)((char*)mod + AOWL_CG_MOD_COUNT_OFF);
        ptrs   = *(void***)((char*)mod + AOWL_CG_MOD_PTRS_OFF);

        if (!ptrs || mcount == 0u) {
            aowl_codegen_last_reason = AOWL_CG_NO_METHOD_TABLE; return NULL;
        }
        if (rid < 1u || rid > mcount) {
            aowl_codegen_last_reason = AOWL_CG_RID_RANGE; return NULL;
        }
        slot = (void*)((char*)ptrs + (uintptr_t)(rid - 1u) * 8u);
        if (!aowl_is_readable(slot, 8)) {
            aowl_codegen_last_reason = AOWL_CG_SLOT_UNREADABLE; return NULL;
        }
        fn = *(void**)slot;
        if (!fn) {
            aowl_codegen_last_reason = AOWL_CG_SLOT_NULL; return NULL;
        }
        if (!aowl_in_il2cpp_section(fn)) {
            aowl_codegen_last_reason = AOWL_CG_NOT_IL2CPP_SECTION; return NULL;
        }
        if (!aowl_is_code_pointer(fn)) {
            aowl_codegen_last_reason = AOWL_CG_NOT_EXECUTABLE; return NULL;
        }
        aowl_codegen_last_reason = AOWL_CG_OK;
        return fn;
    }

    aowl_codegen_last_reason = AOWL_CG_MODULE_NOT_FOUND;
    return NULL;
}

/* Bookkeeping for the read-only agreement check. Called by the host when it has
 * BOTH a live `methodPointer` and a codeGenModule result for the same method.
 * Returns 1 if they agree. */
static int32_t aowl_codegen_note_agreement(void* live, void* resolved) {
    if (live && resolved && live == resolved) { ++aowl_codegen_agreement_same; return 1; }
    ++aowl_codegen_agreement_diff;
    return 0;
}
static int32_t aowl_codegen_agree_same(void) { return aowl_codegen_agreement_same; }
static int32_t aowl_codegen_agree_diff(void) { return aowl_codegen_agreement_diff; }

#endif /* AOWLSPT_CODEGEN_H */
