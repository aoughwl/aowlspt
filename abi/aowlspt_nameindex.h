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
 *   then three parallel arrays of `count`:
 *     u64 hash[]   ascending, UNIQUE      (binary search touches only this)
 *     u32 rva[]
 *     u32 check[]
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
#define AOWL_NIDX_VERSION     1u
#define AOWL_NIDX_HEADER      40u

/* Caps. Nothing here loops without one. */
#define AOWL_NIDX_MAX_ENTRIES 4000000u      /* ~64 MB of index; this build: 321551 */
#define AOWL_NIDX_MAX_FILE    (96u * 1024u * 1024u)
#define AOWL_NIDX_MAX_PROBES  64            /* log2(4e6) = 22; 64 is slack, not a limit */
#define AOWL_NIDX_MAX_KEY     512
#define AOWL_NIDX_MAX_FAULTS  8

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
/* Why a refusal happened, in a sentence naming WHICH check declined. A feature
 * that declines silently is the worst outcome this project produces. */
static char           aowl_nidx_reason[320] = "not initialised";

static const char *aowl_nameidx_reason(void) { return aowl_nidx_reason; }
static int32_t     aowl_nameidx_ready(void)  { return aowl_nidx_ok; }
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
static void *aowl_nidx_image_key_probe(void *out) {
    uint64_t *slot = (uint64_t *)out;
    unsigned char *base = (unsigned char *)GetModuleHandleA("GameAssembly.dll");
    uint32_t e_lfanew, tds, entry, sizeimg, csum;
    unsigned char *nt;
    uint64_t k;

    if (!base) return 0;
    if (!aowl_is_readable(base, 0x40)) return 0;
    if (base[0] != 'M' || base[1] != 'Z') return 0;
    e_lfanew = *(uint32_t *)(base + 0x3C);
    if (e_lfanew < 0x40 || e_lfanew > 0x1000) return 0;

    nt = base + e_lfanew;
    /* 4 signature + 20 COFF + enough of the optional header to reach CheckSum. */
    if (!aowl_is_readable(nt, 4 + 20 + 68)) return 0;
    if (nt[0] != 'P' || nt[1] != 'E' || nt[2] != 0 || nt[3] != 0) return 0;

    tds     = *(uint32_t *)(nt + 4 + 4);        /* COFF TimeDateStamp   */
    entry   = *(uint32_t *)(nt + 24 + 16);      /* Optional AddressOfEntryPoint */
    sizeimg = *(uint32_t *)(nt + 24 + 56);      /* Optional SizeOfImage */
    csum    = *(uint32_t *)(nt + 24 + 64);      /* Optional CheckSum    */

    k = ((uint64_t)tds ^ ((uint64_t)sizeimg * AOWL_NIDX_FNV_PRIME));
    k = (k * AOWL_NIDX_FNV_PRIME) ^ (uint64_t)entry;
    k = (k * AOWL_NIDX_FNV_PRIME) ^ (uint64_t)csum;
    if (k == 0) k = 1;   /* 0 is the "could not read" sentinel */
    *slot = k;
    return out;
}

static uint64_t aowl_nidx_image_key_guarded(void) {
    uint64_t k = 0;
    /* The ONLY guard in this file, and nothing above it holds one at init. */
    if (!aowl_p_p_seh((void *)aowl_nidx_image_key_probe, (void *)&k)) return 0;
    return k;
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
    uint64_t want_key, have_key;
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
        aowl_nidx_fail("aowlspt-names.idx version/count is not one this host reads");
        aowl_nidx_faults++;
        return 0;
    }
    /* Bound the arrays against the REAL file size before reading one entry, so
     * every later index is in range by construction rather than by a check. */
    need = (size_t)AOWL_NIDX_HEADER + (size_t)count * 16u;
    if ((LONGLONG)need != sz.QuadPart) {
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("aowlspt-names.idx size does not match its own entry "
                       "count -- truncated or corrupt");
        aowl_nidx_faults++;
        return 0;
    }

    want_key = *(uint64_t *)(buf + 16);
    have_key = aowl_nidx_image_key_guarded();
    if (have_key == 0) {
        HeapFree(GetProcessHeap(), 0, buf);
        aowl_nidx_fail("could not read GameAssembly.dll's PE headers to verify "
                       "the index build stamp; refusing the index rather than "
                       "trusting it unverified");
        aowl_nidx_faults++;
        return 0;
    }
    if (have_key != want_key) {
        HeapFree(GetProcessHeap(), 0, buf);
        /* The important refusal. A stale RVA is a wrong-but-mapped function. */
        aowl_nidx_fail("STALE INDEX -- aowlspt-names.idx was generated from a "
                       "DIFFERENT GameAssembly.dll than the one loaded. Every "
                       "RVA in it would be a wrong-but-mapped address, so the "
                       "WHOLE index is refused. Regenerate it: "
                       "tools/il2cpp_nameindex.py gen");
        aowl_nidx_faults++;
        return 0;
    }

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
    aowl_nidx_buf       = buf;
    aowl_nidx_count     = count;
    aowl_nidx_image_key = have_key;
    aowl_nidx_file_hash = *(uint64_t *)(buf + 24);
    aowl_nidx_ok        = 1;
    aowl_nidx_reason[0] = 0;
    return 1;
}

static void aowl_nameidx_shutdown(void) {
    if (aowl_nidx_buf) HeapFree(GetProcessHeap(), 0, aowl_nidx_buf);
    aowl_nidx_buf = 0;
    aowl_nidx_count = 0;
    aowl_nidx_ok = 0;
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
static uint32_t aowl_nameidx_lookup(const char *spec, int32_t arity) {
    char key[AOWL_NIDX_MAX_KEY];
    int32_t n = 0, probes = 0;
    uint64_t want;
    uint32_t chk;
    const uint64_t *hashes;
    const uint32_t *rvas, *checks;
    uint32_t lo, hi;

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
            return rvas[mid];
        }
        if (got < want) { lo = mid + 1u; }
        else { if (mid == 0) break; hi = mid - 1u; }
    }
    return 0;
}

#endif /* AOWLSPT_NAMEINDEX_H */
