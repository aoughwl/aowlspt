/* aowlspt_nameindex.h -- name -> code-RVA lookup from a generated offline index.
 *
 * ## What this replaces, and why it has to exist
 *
 * By-name method resolution is DEAD on this build. `findClass`/`findMethod`
 * hand back non-nil handles into unmapped memory, and every `MethodInfo` probed
 * through them is unreadable -- measured 6/6 on the host thread AND 6/6 on the
 * Unity main thread, so it is not thread affinity. No MethodInfo means no
 * token, and no token means the `Il2CppCodeGenModule.methodPointers` table --
 * which is itself sound, hand-walked live and prologue byte-verified -- cannot
 * be indexed BY NAME at run time.
 *
 * Every input to that resolution is available offline, though. So
 * `tools/il2cpp_nameindex.py` walks the metadata on the build machine, does
 * exactly what `tools/il2cpp_resolve.py` does (it imports it, rather than
 * reimplementing the walk, so the two cannot drift), and freezes the whole
 * answer into a sorted binary index. This file only reads that file. It calls
 * NOTHING in IL2CPP -- not one export, not one MethodInfo dereference. That is
 * the entire point: the dead path is not made more robust here, it is removed
 * from the question.
 *
 * ## What it does NOT do
 *
 * It does not patch, bind, verify a prologue, or turn an RVA into a callable
 * pointer. It answers ONE question -- "what RVA does this name have" -- and the
 * caller takes that to the by-RVA binder, which owns address substitution,
 * prologue byte-verification against the startup snapshot, the `VirtualQuery`
 * and the il2cpp-section check. There is deliberately no second copy of any of
 * that in this file.
 *
 * ## The file format (little-endian throughout)
 *
 *   header, 40 bytes:
 *     +0x00  "AOWLNIDX"
 *     +0x08  u32 version (1)
 *     +0x0C  u32 count
 *     +0x10  u64 imageKey    -- build identity, verifiable from mapped headers
 *     +0x18  u64 fileHash    -- SHA-256(GameAssembly.dll)[0:8], build-time guard
 *     +0x20  u32 flags, u32 pad
 *   then FOUR parallel arrays of `count` (format version 2):
 *     u64 hash[]   ascending, UNIQUE      (binary search touches only this)
 *     u32 rva[]
 *     u32 check[]
 *     u16 share[]  how many method keys resolve to that rva
 *
 * ## SHARED RVAs, and why the count is a FIELD and not a companion file
 *
 * The IL2CPP backend folds identical compiled bodies, so unrelated methods in
 * different images share one address. Measured on this build: 6,261 RVAs are
 * reached by more than one method key, 28.3% of exact keys (46,608 of 164,922)
 * land on one, and 0x628110 -- the universal `ret 0` stub -- is shared by
 * 6,438 methods. `Diz.Resources.EasyAssets::get_System` is one of 338 keys on
 * 0x692A50.
 *
 * CALLING a shared RVA is fine: it is the right code for the receiver passed.
 * DETOURING one is a write whose blast radius is every method that folded onto
 * it, and nothing at run time can tell them apart. So `share[]` exists, and
 * `aowl_nameidx_lookup_shared` hands the count to the caller.
 *
 *   share == 0    sharedness UNKNOWN. NEVER "unshared".
 *   share == 1    reached by this method only.
 *   share >= 2    that many methods resolve here (saturating at 65535).
 *
 * It is a field rather than a stamped sidecar because a sidecar is a second
 * file that can go missing on its own -- which is exactly what happened: the
 * generator wrote one, nothing deployed it, and the host had no sharedness
 * data at all while by-name patching was live. One file, one stamp, one
 * staleness story. A version-1 index cannot answer the question, so it is
 * REFUSED at load by the same door that refuses a stale stamp, rather than
 * loaded and silently read as all-unshared.
 *
 * Structure-of-arrays so the search walks a dense 8-byte-stride array instead of
 * striding a 16-byte record and pulling an rva+check into cache at every probe
 * it is going to discard.
 *
 * ## Why a hash and not the names
 *
 * 4.91 MB rather than ~8.8 MB, and the host never needs to print a name it was
 * not already handed by the caller. Two independent guards make that safe:
 *
 *  - a PRIMARY collision (two distinct keys, one u64) is detected OFFLINE over
 *    the complete key set, and the generator REFUSES to emit. It cannot reach
 *    this file.
 *  - a lookup for a key that is NOT in the index could still land on a matching
 *    primary. So every entry carries a 32-bit CHECK hash from an independent
 *    basis and prime, verified after the search. A false hit needs both to
 *    collide: ~2^-96. On a check mismatch this reports NOT FOUND, which is the
 *    recoverable answer.
 *
 * ## Overloads
 *
 * Keys carry arity, because a name does not identify a method:
 * `UnityEngine.AssetBundle::LoadAsset` has two, at 0x5250100 and 0x5250340.
 *
 *   "Ns.Type::Method/2"   the 2-argument overload, exactly
 *   "Ns.Type::Method/*"   emitted by the generator ONLY where the name has a
 *                         single overload
 *
 * So an arity of -1 -- the host's existing "a patch names a method, not a
 * signature" lookup -- maps to the `/*` key, which ANSWERS when there is
 * nothing to be ambiguous about and is ABSENT the moment there is. `LoadAsset`
 * with arity -1 returns NOT FOUND here, on purpose, and the caller must name
 * the overload it means.
 *
 * The generator also DROPS any key that two metadata types gave two different
 * RVAs (4675 of them on this build -- closure types, nested types carrying no
 * namespace). There is no correct answer for those, so there is no answer.
 *
 * ## Staleness is the real hazard
 *
 * A stale RVA is not a missing function, it is a WRONG-BUT-MAPPED one, which is
 * precisely the corruption the safety rules exist to prevent. So the index is
 * stamped and the stamp is checked at load:
 *
 *   `imageKey` is packed from PE header fields -- TimeDateStamp, SizeOfImage,
 *   AddressOfEntryPoint, CheckSum -- that the loader maps verbatim and does not
 *   touch. So it is reproducible from `GetModuleHandleA("GameAssembly.dll")` in
 *   microseconds, with no file I/O and no 124 MB rehash at startup.
 *
 * On mismatch this refuses the WHOLE index and serves nothing from it, rather
 * than answering with addresses from another build. Prologue byte-verification
 * before patching remains mandatory regardless: the stamp narrows the window,
 * it does not replace the check.
 *
 * ## Safety
 *
 * The index buffer is our own heap, sized from a header validated against the
 * real file size before a single entry is read, so the search needs no guard
 * and adds none -- `aowl_p_p_seh` is not re-entrant and a nested guard would
 * DISARM an outer one. The one place that touches foreign memory is the mapped
 * PE header read in `init`, which is `aowl_is_readable`-gated and runs under a
 * single guard of its own at a point where no other guard is held. Every loop
 * is capped. The feature is flag-gated and default OFF, and self-disables after
 * AOWL_NIDX_MAX_FAULTS refusals.
 *
 * Regenerate with:
 *   python tools/il2cpp_nameindex.py gen \
 *       D:/Games/Tarkov/GameAssembly.dll .cache/global-metadata.dec.dat \
 *       build/aowlspt-names.idx
 */

#ifndef AOWLSPT_NAMEINDEX_H
#define AOWLSPT_NAMEINDEX_H

#include <windows.h>
#include <stdint.h>
#include <string.h>

/* aowl_is_readable / aowl_p_p_seh */
#include "aowlspt_shim.h"

#define AOWL_NIDX_MAGIC0      0x4C574F41u   /* "AOWL" */
#define AOWL_NIDX_MAGIC1      0x5844494Eu   /* "NIDX" */
#define AOWL_NIDX_VERSION     2u
#define AOWL_NIDX_ENTRY       18u  /* u64 hash + u32 rva + u32 check + u16 share */
/* Share-count sentinels. Kept in one place so the host and
 * tools/il2cpp_nameindex.py cannot drift on what 0 means. */
#define AOWL_NIDX_SHARE_UNKNOWN 0u
#define AOWL_NIDX_HEADER      40u

/* Caps. Nothing here loops without one. */
#define AOWL_NIDX_MAX_ENTRIES 4000000u      /* ~64 MB of index; this build: 321551 */
#define AOWL_NIDX_MAX_FILE    (96u * 1024u * 1024u)
#define AOWL_NIDX_MAX_PROBES  64            /* log2(4e6) = 22; 64 is slack, not a limit */
#define AOWL_NIDX_MAX_KEY     512
#define AOWL_NIDX_MAX_FAULTS  8
/* How many times first-use may re-ask for the mapped module before giving up.
 * Bounded like every other loop here; one try per `ready()` call. */
#define AOWL_NIDX_MAX_STAMP_TRIES 256

/* Which check declined, so the message can name it rather than blame the
 * headers for a module that is not mapped. */
#define AOWL_NIDX_ST_FAULT     0   /* pre-set; survives an SEH unwind */
#define AOWL_NIDX_ST_OK        1
#define AOWL_NIDX_ST_NOMODULE  2
#define AOWL_NIDX_ST_DOSSPAN   3
#define AOWL_NIDX_ST_NOMZ      4
#define AOWL_NIDX_ST_LFANEW    5
#define AOWL_NIDX_ST_NTSPAN    6
#define AOWL_NIDX_ST_NOPE      7

typedef struct {
    uint64_t key;
    uint64_t addr;      /* the address the failing check was looking at */
    uint32_t lfanew;
    int32_t  status;
} aowl_nidx_stamp_t;

/* Must match tools/il2cpp_nameindex.py exactly. */
#define AOWL_NIDX_FNV_BASIS   0xCBF29CE484222325ULL
#define AOWL_NIDX_FNV_PRIME   0x00000100000001B3ULL
#define AOWL_NIDX_CHK_BASIS   0x9E3779B97F4A7C15ULL
#define AOWL_NIDX_CHK_PRIME   0x00000100000001B7ULL

static unsigned char *aowl_nidx_buf = 0;
static uint32_t       aowl_nidx_count = 0;
static uint64_t       aowl_nidx_image_key = 0;
static uint64_t       aowl_nidx_file_hash = 0;
static int32_t        aowl_nidx_ok = 0;
static int32_t        aowl_nidx_faults = 0;
/* The index file can be read long before GameAssembly.dll is mapped: this host
 * initialises at DLL-attach, ~15ms in, and the Unity player loads the IL2CPP
 * module about a second later. That is NOT "the PE headers are unreadable" --
 * it is "there is no module to read yet", and the two used to share one
 * message. The file is parsed and STAGED, `aowl_nidx_ok` stays 0 so nothing
 * resolves, and the stamp is verified on first use. */
static int32_t        aowl_nidx_staged = 0;
static int32_t        aowl_nidx_stamp_tries = 0;
/* Why a refusal happened, in a sentence naming WHICH check declined. A feature
 * that declines silently is the worst outcome this project produces. */
static char           aowl_nidx_reason[320] = "not initialised";

static const char *aowl_nameidx_reason(void) { return aowl_nidx_reason; }
static int32_t     aowl_nameidx_ready(void);   /* defined below; may verify */
/* Parsed and sound, but the build stamp is not verified yet because the
 * module was not mapped. Not an error, and not usable either. */
static int32_t     aowl_nameidx_staged(void) { return aowl_nidx_staged; }
static int32_t     aowl_nameidx_count(void)  { return (int32_t)aowl_nidx_count; }
static uint64_t    aowl_nameidx_imagekey(void) { return aowl_nidx_image_key; }
static uint64_t    aowl_nameidx_filehash(void) { return aowl_nidx_file_hash; }

static void aowl_nidx_fail(const char *why) {
    strncpy(aowl_nidx_reason, why, sizeof(aowl_nidx_reason) - 1);
    aowl_nidx_reason[sizeof(aowl_nidx_reason) - 1] = 0;
    aowl_nidx_ok = 0;
}

static uint64_t aowl_nidx_h_primary(const char *s, int32_t n) {
    uint64_t h = AOWL_NIDX_FNV_BASIS;
    int32_t i;
    for (i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * AOWL_NIDX_FNV_PRIME;
    return h;
}

static uint32_t aowl_nidx_h_check(const char *s, int32_t n) {
    uint64_t h = AOWL_NIDX_CHK_BASIS;
    int32_t i;
    for (i = 0; i < n; i++) h = (h ^ (unsigned char)s[i]) * AOWL_NIDX_CHK_PRIME;
    return (uint32_t)((h >> 32) ^ (h & 0xFFFFFFFFULL));
}

/* -- the build stamp, read from the MAPPED module -------------------------- */

/* Runs under its own `aowl_p_p_seh` (see `aowl_nidx_image_key_guarded`). Every
 * hop is `aowl_is_readable`-gated first, so the guard is a backstop and not the
 * mechanism. Writes through `out`; returns non-null on success. */
/* A bounded "append" pair, so the failure message can name the address without
 * pulling in <stdio.h> or user32's wsprintf. */
static void aowl_nidx_cat(char *dst, int32_t cap, int32_t *at, const char *src) {
    int32_t i = 0;
    while (*at < cap - 1 && src[i] && i < 512) dst[(*at)++] = src[i++];
    dst[*at] = 0;
}
static void aowl_nidx_cathex(char *dst, int32_t cap, int32_t *at, uint64_t v) {
    static const char hx[] = "0123456789ABCDEF";
    char tmp[17];
    int32_t d = 0;
    aowl_nidx_cat(dst, cap, at, "0x");
    if (v == 0) { aowl_nidx_cat(dst, cap, at, "0"); return; }
    while (v && d < 16) { tmp[d++] = hx[v & 0xF]; v >>= 4; }
    while (d > 0 && *at < cap - 1) dst[(*at)++] = tmp[--d];
    dst[*at] = 0;
}

static void *aowl_nidx_image_key_probe(void *out) {
    aowl_nidx_stamp_t *st = (aowl_nidx_stamp_t *)out;
    unsigned char *base = (unsigned char *)GetModuleHandleA("GameAssembly.dll");
    uint32_t e_lfanew, tds, entry, sizeimg, csum;
    unsigned char *nt;
    uint64_t k;

    /* `status` is pre-set to FAULT by the caller and `addr` is updated BEFORE
     * each read, never after: a caught access violation unwinds this whole body
     * silently, so any bookkeeping placed after a faulting read never runs. */
    if (!base) { st->status = AOWL_NIDX_ST_NOMODULE; return 0; }
    st->addr = (uint64_t)(uintptr_t)base;
    if (!aowl_is_readable(base, 0x40)) { st->status = AOWL_NIDX_ST_DOSSPAN; return 0; }
    if (base[0] != 'M' || base[1] != 'Z') { st->status = AOWL_NIDX_ST_NOMZ; return 0; }

    st->addr = (uint64_t)(uintptr_t)(base + 0x3C);
    e_lfanew = *(uint32_t *)(base + 0x3C);
    st->lfanew = e_lfanew;
    if (e_lfanew < 0x40 || e_lfanew > 0x1000) { st->status = AOWL_NIDX_ST_LFANEW; return 0; }

    nt = base + e_lfanew;
    st->addr = (uint64_t)(uintptr_t)nt;
    /* 4 signature + 20 COFF + enough of the optional header to reach CheckSum.
     * 92 bytes, and the mapped headers are their own PAGE_READONLY region of at
     * least one page, so this span does not straddle a region boundary -- the
     * trap `aowl_is_readable` sets for spans that do. */
    if (!aowl_is_readable(nt, 4 + 20 + 68)) { st->status = AOWL_NIDX_ST_NTSPAN; return 0; }
    if (nt[0] != 'P' || nt[1] != 'E' || nt[2] != 0 || nt[3] != 0) {
        st->status = AOWL_NIDX_ST_NOPE; return 0;
    }

    tds     = *(uint32_t *)(nt + 4 + 4);        /* COFF TimeDateStamp   */
    entry   = *(uint32_t *)(nt + 24 + 16);      /* Optional AddressOfEntryPoint */
    sizeimg = *(uint32_t *)(nt + 24 + 56);      /* Optional SizeOfImage */
    csum    = *(uint32_t *)(nt + 24 + 64);      /* Optional CheckSum    */

    k = ((uint64_t)tds ^ ((uint64_t)sizeimg * AOWL_NIDX_FNV_PRIME));
    k = (k * AOWL_NIDX_FNV_PRIME) ^ (uint64_t)entry;
    k = (k * AOWL_NIDX_FNV_PRIME) ^ (uint64_t)csum;
    if (k == 0) k = 1;   /* 0 is the "could not read" sentinel */
    st->key = k;
    st->status = AOWL_NIDX_ST_OK;
    return out;
}

/* Runs the probe under exactly ONE guard. `aowl_p_p_seh` is NOT re-entrant --
 * a nested arm disarms the outer one -- and this is reachable from first-use
 * paths that may already hold a guard, so when one is held on this thread the
 * probe is called directly and the OUTER guard covers it. Every hop inside is
 * `aowl_is_readable`-gated anyway; the guard is a backstop, not the mechanism. */
static void aowl_nidx_read_stamp(aowl_nidx_stamp_t *st) {
    st->key = 0;
    st->addr = 0;
    st->lfanew = 0;
    st->status = AOWL_NIDX_ST_FAULT;
    if (aowl_seh_active) {
        (void)aowl_nidx_image_key_probe((void *)st);
    } else {
        (void)aowl_p_p_seh((void *)aowl_nidx_image_key_probe, (void *)st);
    }
}

/* Verify the staged index's build stamp against the mapped module.
 *   1 -- verified, the index is now live
 *   0 -- not yet: GameAssembly.dll is not mapped. Stays staged, retried later.
 *  -1 -- refused for good; the buffer has been freed.
 *
 * ONLY `imageKey` is checkable here. The index also carries `fileHash`
 * (SHA-256 of GameAssembly.dll on disk) and that is NOT reproducible from a
 * mapped image -- the loader page-aligns and relocates sections, so the mapped
 * bytes are not the file bytes. It stays a build-time guard, checked offline by
 * `tools/il2cpp_nameindex.py check`, and the log says so rather than implying
 * more was verified than was. */
static int32_t aowl_nidx_verify_stamp(void) {
    aowl_nidx_stamp_t st;
    uint64_t want;
    char msg[320];

    if (!aowl_nidx_staged || !aowl_nidx_buf) {
        aowl_nidx_fail("no staged index to verify");
        return -1;
    }
    want = *(uint64_t *)(aowl_nidx_buf + 16);

    if (aowl_nidx_stamp_tries >= AOWL_NIDX_MAX_STAMP_TRIES) {
        HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
        aowl_nidx_buf = 0; aowl_nidx_staged = 0; aowl_nidx_count = 0;
        aowl_nidx_fail("GameAssembly.dll never became visible to "
                       "GetModuleHandleA across every retry, so the index "
                       "build stamp could never be verified; refusing it "
                       "rather than trusting it unverified");
        aowl_nidx_faults++;
        return -1;
    }
    aowl_nidx_stamp_tries++;
    aowl_nidx_read_stamp(&st);

    if (st.status != AOWL_NIDX_ST_OK) {
        if (st.status == AOWL_NIDX_ST_NOMODULE) {
            aowl_nidx_fail("GameAssembly.dll is not mapped yet -- "
                           "GetModuleHandleA(GameAssembly.dll) returned NULL, "
                           "which at DLL-attach is EXPECTED and is NOT a "
                           "header-read failure. The index file is parsed and "
                           "STAGED; its build stamp is verified at first use, "
                           "and nothing resolves through it until then");
            return 0;   /* retryable: NOT a fault, NOT a refusal */
        }
        /* Everything else is a real read failure. Name the check and where. */
        {
            const char *what =
                st.status == AOWL_NIDX_ST_DOSSPAN ? "the 0x40-byte DOS header span is unreadable at" :
                st.status == AOWL_NIDX_ST_NOMZ    ? "no MZ signature at base+0x00, i.e." :
                st.status == AOWL_NIDX_ST_LFANEW  ? "e_lfanew is outside 0x40..0x1000, read at" :
                st.status == AOWL_NIDX_ST_NTSPAN  ? "the 92-byte NT-header span (signature..CheckSum) is unreadable at" :
                st.status == AOWL_NIDX_ST_NOPE    ? "no PE\\0\\0 signature at" :
                                                    "the read FAULTED (guard tripped) at";
            int32_t at = 0;
            msg[0] = 0;
            aowl_nidx_cat(msg, (int32_t)sizeof(msg), &at,
                          "build-stamp read failed: ");
            aowl_nidx_cat(msg, (int32_t)sizeof(msg), &at, what);
            aowl_nidx_cat(msg, (int32_t)sizeof(msg), &at, " ");
            aowl_nidx_cathex(msg, (int32_t)sizeof(msg), &at, st.addr);
            aowl_nidx_cat(msg, (int32_t)sizeof(msg), &at, " (e_lfanew=");
            aowl_nidx_cathex(msg, (int32_t)sizeof(msg), &at, (uint64_t)st.lfanew);
            aowl_nidx_cat(msg, (int32_t)sizeof(msg), &at,
                          "). Refusing the index rather than trusting it "
                          "unverified");
        }
        HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
        aowl_nidx_buf = 0; aowl_nidx_staged = 0; aowl_nidx_count = 0;
        aowl_nidx_fail(msg);
        aowl_nidx_faults++;
        return -1;
    }

    if (st.key != want) {
        HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
        aowl_nidx_buf = 0; aowl_nidx_staged = 0; aowl_nidx_count = 0;
        /* The important refusal. A stale RVA is a wrong-but-mapped function. */
        aowl_nidx_fail("STALE INDEX -- aowlspt-names.idx was generated from a "
                       "DIFFERENT GameAssembly.dll than the one loaded "
                       "(imageKey mismatch). Every RVA in it would be a "
                       "wrong-but-mapped address, so the WHOLE index is "
                       "refused. Regenerate it: tools/il2cpp_nameindex.py gen");
        aowl_nidx_faults++;
        return -1;
    }

    aowl_nidx_image_key = st.key;
    aowl_nidx_file_hash = *(uint64_t *)(aowl_nidx_buf + 24);
    aowl_nidx_staged = 0;
    aowl_nidx_ok = 1;
    aowl_nidx_reason[0] = 0;
    return 1;
}

/* -- load ------------------------------------------------------------------ */

/* Reads `<dir>/aowlspt-names.idx`, validates it, and verifies the build stamp.
 * Returns 1 on success. On ANY refusal it frees everything and leaves
 * `aowl_nameidx_reason()` naming the check that declined. */
static int32_t aowl_nameidx_init(const char *dir) {
    char path[MAX_PATH];
    HANDLE h;
    LARGE_INTEGER sz;
    DWORD got = 0;
    unsigned char *buf;
    uint32_t ver, count, i;
    size_t need;
    const uint64_t *hashes;

    aowl_nidx_ok = 0;
    if (aowl_nidx_faults >= AOWL_NIDX_MAX_FAULTS) {
        aowl_nidx_fail("name index self-disabled after repeated load failures");
        return 0;
    }
    if (!dir) { aowl_nidx_fail("no host directory"); aowl_nidx_faults++; return 0; }

    /* Built by hand rather than with `_snprintf`: no <stdio.h> dependency, and
     * the bound is visible. `aowl_nidx_name` is 18 chars plus a separator. */
    {
        static const char leaf[] = "\\aowlspt-names.idx";
        int32_t p = 0;
        while (p < (int32_t)sizeof(path) - (int32_t)sizeof(leaf) - 1 && dir[p]) {
            path[p] = dir[p];
            p++;
        }
        if (dir[p]) {
            aowl_nidx_fail("host directory path is too long for the index path");
            aowl_nidx_faults++;
            return 0;
        }
        memcpy(path + p, leaf, sizeof(leaf));   /* includes the NUL */
    }

    h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING,
                    FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) {
        aowl_nidx_fail("no aowlspt-names.idx beside the host DLL; generate it "
                       "with tools/il2cpp_nameindex.py gen and deploy it");
        aowl_nidx_faults++;
        return 0;
    }
    if (!GetFileSizeEx(h, &sz) || sz.QuadPart < (LONGLONG)AOWL_NIDX_HEADER ||
        sz.QuadPart > (LONGLONG)AOWL_NIDX_MAX_FILE) {
        CloseHandle(h);
        aowl_nidx_fail("aowlspt-names.idx has an impossible size");
        aowl_nidx_faults++;
        return 0;
    }

    buf = (unsigned char *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)sz.QuadPart);
    if (!buf) {
        CloseHandle(h);
        aowl_nidx_fail("out of memory reading aowlspt-names.idx");
        aowl_nidx_faults++;
        return 0;
    }
    if (!ReadFile(h, buf, (DWORD)sz.QuadPart, &got, 0) ||
        got != (DWORD)sz.QuadPart) {
        CloseHandle(h);
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("short read on aowlspt-names.idx");
        aowl_nidx_faults++;
        return 0;
    }
    CloseHandle(h);

    if (*(uint32_t *)(buf + 0) != AOWL_NIDX_MAGIC0 ||
        *(uint32_t *)(buf + 4) != AOWL_NIDX_MAGIC1) {
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("aowlspt-names.idx is not an aowlspt name index (bad magic)");
        aowl_nidx_faults++;
        return 0;
    }
    ver   = *(uint32_t *)(buf + 8);
    count = *(uint32_t *)(buf + 12);
    if (ver != AOWL_NIDX_VERSION || count == 0 || count > AOWL_NIDX_MAX_ENTRIES) {
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("aowlspt-names.idx is format version 1, which carries "
                       "NO per-entry share count -- so it cannot say whether "
                       "an RVA is shared by many folded methods, and reading "
                       "that silence as \"unshared\" is exactly the "
                       "confidently-wrong answer this host refuses to give. "
                       "(Or the entry count is out of range.) Regenerate: "
                       "tools/il2cpp_nameindex.py gen");
        aowl_nidx_faults++;
        return 0;
    }
    /* Bound the arrays against the REAL file size before reading one entry, so
     * every later index is in range by construction rather than by a check. */
    need = (size_t)AOWL_NIDX_HEADER + (size_t)count * (size_t)AOWL_NIDX_ENTRY;
    if ((LONGLONG)need != sz.QuadPart) {
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("aowlspt-names.idx size does not match its own entry "
                       "count -- truncated or corrupt");
        aowl_nidx_faults++;
        return 0;
    }

    /* The build stamp is NOT verified here. Verification needs the mapped
     * module and this runs at DLL-attach, before the Unity player has loaded
     * GameAssembly.dll -- see `aowl_nidx_verify_stamp`. */

    /* The generator emits ascending unique hashes; a binary search over an
     * unsorted array silently returns wrong entries rather than failing, so it
     * is confirmed here rather than assumed. Capped by `count`, which the size
     * check above already bounded. */
    hashes = (const uint64_t *)(buf + AOWL_NIDX_HEADER);
    for (i = 1; i < count; i++) {
        if (hashes[i] <= hashes[i - 1]) {
            HeapFree(GetProcessHeap(), 0, buf);
            aowl_nidx_fail("aowlspt-names.idx hash array is not strictly "
                           "ascending -- a binary search over it would return "
                           "wrong addresses, so it is refused");
            aowl_nidx_faults++;
            return 0;
        }
    }

    if (aowl_nidx_buf) HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
    aowl_nidx_buf         = buf;
    aowl_nidx_count       = count;
    aowl_nidx_image_key   = 0;
    aowl_nidx_file_hash   = 0;
    aowl_nidx_ok          = 0;
    aowl_nidx_staged      = 1;
    aowl_nidx_stamp_tries = 0;
    /* The file is sound. Whether it describes THIS GameAssembly.dll is decided
     * by the stamp, attempted now and retried at first use if the module is
     * not mapped yet. `aowl_nidx_ok` is only ever set by that check. */
    return aowl_nidx_verify_stamp() == 1 ? 1 : 0;
}

/* Ready means VERIFIED. A staged-but-unverified index answers nothing, and
 * asking re-attempts the stamp -- which is how an index loaded at DLL-attach
 * goes live once GameAssembly.dll appears, without a second file read. */
static int32_t aowl_nameidx_ready(void) {
    if (aowl_nidx_ok) return 1;
    if (aowl_nidx_staged) (void)aowl_nidx_verify_stamp();
    return aowl_nidx_ok;
}

static void aowl_nameidx_shutdown(void) {
    if (aowl_nidx_buf) HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
    aowl_nidx_buf = 0;
    aowl_nidx_count = 0;
    aowl_nidx_ok = 0;
    aowl_nidx_staged = 0;
    aowl_nidx_fail("shut down");
}

/* -- lookup ---------------------------------------------------------------- */

/* `spec` is "Namespace.Type::Method". `arity` is the parameter count, or -1 for
 * "the only overload", which ANSWERS only where there is exactly one.
 *
 * Returns the RVA, or 0 for not-found. 0 is unambiguous: RVA 0 is the DOS
 * header, never a method, and the generator rejects it. Touches only our own
 * validated heap buffer, so it takes no guard and -- deliberately -- adds none.
 */
static uint32_t aowl_nameidx_lookup_shared(const char *spec, int32_t arity,
                                           uint32_t *share_out) {
    char key[AOWL_NIDX_MAX_KEY];
    int32_t n = 0, probes = 0;
    uint64_t want;
    uint32_t chk;
    const uint64_t *hashes;
    const uint32_t *rvas, *checks;
    const uint16_t *shares;
    uint32_t lo, hi;

    /* Pre-set, and never cleared on a failure path: every early return below
     * leaves sharedness UNKNOWN, which is the answer that refuses a patch. */
    if (share_out) *share_out = AOWL_NIDX_SHARE_UNKNOWN;
    if (!aowl_nidx_ok || !aowl_nidx_buf || !spec) return 0;

    while (n < AOWL_NIDX_MAX_KEY - 16 && spec[n]) { key[n] = spec[n]; n++; }
    if (spec[n]) return 0;              /* spec longer than any real key */
    key[n++] = '/';
    if (arity < 0) {
        key[n++] = '*';
    } else if (arity > 4095) {
        return 0;
    } else {
        char digits[8];
        int32_t d = 0, v = arity;
        if (v == 0) digits[d++] = '0';
        while (v > 0 && d < 8) { digits[d++] = (char)('0' + (v % 10)); v /= 10; }
        while (d > 0) key[n++] = digits[--d];
    }

    want = aowl_nidx_h_primary(key, n);
    chk  = aowl_nidx_h_check(key, n);

    hashes = (const uint64_t *)(aowl_nidx_buf + AOWL_NIDX_HEADER);
    rvas   = (const uint32_t *)(aowl_nidx_buf + AOWL_NIDX_HEADER +
                                (size_t)aowl_nidx_count * 8u);
    checks = (const uint32_t *)(aowl_nidx_buf + AOWL_NIDX_HEADER +
                                (size_t)aowl_nidx_count * 12u);
    shares = (const uint16_t *)(aowl_nidx_buf + AOWL_NIDX_HEADER +
                                (size_t)aowl_nidx_count * 16u);

    lo = 0;
    hi = aowl_nidx_count - 1;
    while (lo <= hi) {
        uint32_t mid;
        uint64_t got;
        if (++probes > AOWL_NIDX_MAX_PROBES) return 0;   /* capped, always */
        mid = lo + (hi - lo) / 2u;
        got = hashes[mid];
        if (got == want) {
            /* The independent second hash. A primary hit on a key that is not
             * in the index would otherwise be a silent wrong address. */
            if (checks[mid] != chk) return 0;
            if (share_out) *share_out = (uint32_t)shares[mid];
            return rvas[mid];
        }
        if (got < want) { lo = mid + 1u; }
        else { if (mid == 0) break; hi = mid - 1u; }
    }
    return 0;
}

/* The address only. Every caller that is about to WRITE (a detour) must use
 * `aowl_nameidx_lookup_shared` and act on the count; this form is for a direct
 * CALL, which is correct code for the receiver it is passed even when the body
 * is folded. */
static uint32_t aowl_nameidx_lookup(const char *spec, int32_t arity) {
    uint32_t share = AOWL_NIDX_SHARE_UNKNOWN;
    return aowl_nameidx_lookup_shared(spec, arity, &share);
}

#endif /* AOWLSPT_NAMEINDEX_H */
