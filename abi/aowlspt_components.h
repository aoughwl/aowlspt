/* aowlspt_components.h -- ask an object WHAT COMPONENTS IT HAS.
 *
 * WHY THIS EXISTS
 * ---------------
 * `component EXPR Type` is a yes/no oracle that charges for wrong guesses.
 * A right guess returns the component; a wrong-but-safe guess returns NULL,
 * which is free; a wrong-and-unlucky guess FAULTS inside
 * `Component::GetComponent(String)` and spends one of the inspector's eight
 * faults for the session. Naming a component you cannot already name therefore
 * costs a session, and it has: an unnamed checkbox component on the raid setup
 * screen defeated four type-name guesses across five ancestors.
 *
 * Enumerating is strictly better than guessing, and it is reachable without
 * reflection.
 *
 *
 * THE ROUTE, AND WHY EACH HOP IS ALLOWED
 * --------------------------------------
 * 1.  A `System.Type` without reflection. `System.Type::GetTypeFromHandle`
 *     takes a `RuntimeTypeHandle`, a one-field struct whose value IS the
 *     `Il2CppType*` -- so on Win64 it is a plain pointer in RCX. The static
 *     `Il2CppType` for any named type is in `.data` and its address is
 *     resolved OFFLINE, out of `Il2CppMetadataRegistration.types`, by
 *     `tools/il2cpp_nameindex.py` under the key `Ns.Type::@type/0`. Nothing
 *     here calls `il2cpp_class_from_il2cpp_type` or any other export.
 *
 * 2.  `UnityEngine.GameObject::GetComponents(Type) -> Component[]`. A real
 *     managed body at a byte-verified RVA. Returns an `Il2CppArray`, read with
 *     the array offsets this repo already uses live for
 *     `Scene::GetRootGameObjects` (`AOWL_NAV_ARR_LEN` / `AOWL_NAV_ARR_DATA`).
 *
 * 3.  Naming each element. Reflection is dead, so the name is read RAW out of
 *     the `Il2CppClass` -- see the offset block below -- and then VALIDATED
 *     against the offline type table before it is printed.
 *
 *
 * THE OFFSETS, AND EXACTLY HOW EACH WAS OBTAINED
 * ---------------------------------------------
 * `Il2CppClass` is a NATIVE struct. It is not in
 * `Il2CppMetadataRegistration.fieldOffsets`, so `il2cpp_resolve.py fields`
 * cannot answer for it and "never guess an offset" needs a different source.
 * The source used here is GameAssembly.dll's OWN EXPORT TABLE: several
 * `il2cpp_*` exports are one-instruction accessors, and their instruction
 * bytes state the offset outright. Read out of the shipped DLL:
 *
 *     il2cpp_object_get_class        48 8b 01 c3        mov rax,[rcx]
 *     il2cpp_class_get_image         48 8b 01 c3        mov rax,[rcx]
 *     il2cpp_class_get_namespace     48 8b 41 18 c3     mov rax,[rcx+0x18]
 *     il2cpp_class_get_element_class 48 8b 41 40 c3     mov rax,[rcx+0x40]
 *     il2cpp_string_length           8b 41 10 c3        mov eax,[rcx+0x10]
 *     il2cpp_array_length            8b 41 18 c3        mov eax,[rcx+0x18]
 *
 * The last two are the CONTROL for the method: `String._stringLength` at
 * +0x10 and the array length at +0x18 are both independently known in this
 * repo (`il2cpp_resolve.py`'s built-in self-check, and `AOWL_NAV_ARR_LEN`).
 * The export bytes reproduce both, so reading offsets out of folded accessors
 * is a method that has been checked, not merely proposed.
 *
 * `AOWL_COMP_KLASS_NAME` IS THE ONE INFERENCE, AND IT IS FENCED.
 * `il2cpp_class_get_name` is NOT an accessor on this build -- it is a
 * TLS-heavy thread-attach wrapper (`48 89 5c 24 10 ... 65 48 8b 04 25 58 00
 * 00 00`, reading the TEB), which is very likely why calling it faults. So
 * +0x10 for `name` is inferred from the canonical `Il2CppClass` head --
 * image(0x00), gc_desc(0x08), name(0x10), namespaze(0x18) -- with 0x00 and
 * 0x18 MEASURED either side of it.
 *
 * An inference must not be allowed to print a plausible wrong type name, so
 * it is not trusted, it is TESTED: whatever string comes back is looked up in
 * the offline type table (`Ns.Type::@name/0`, one key per typedef in this
 * build). A hit means the offset is right for that object and the name is
 * real. A miss prints UNVERIFIED and the raw bytes, and never a type name.
 * If +0x10 were wrong, every single line would say UNVERIFIED -- the failure
 * announces itself instead of lying.
 *
 *
 * SAFETY
 * ------
 * Everything here is called from inside the inspector's per-command
 * `aowl_p_p_seh`, which is NOT re-entrant, so this file opens NO guard of its
 * own. Nesting one would DISARM the caller's, which is worse than having none.
 *
 * It does not need one. Every read here is a fixed-size read at an address
 * VirtualQuery'd first, page by page -- a C string that straddles into an
 * uncommitted page is truncated, not faulted. The component array is capped at
 * AOWL_COMP_MAX; each name copy is capped at AOWL_COMP_NAME_MAX; there is no
 * unbounded loop. Nothing here writes anything, and nothing here calls into
 * game code -- the two managed calls are made by the caller, through the
 * inspector's own verified-call path, so they land inside its guard and its
 * breadcrumb.
 */

#ifndef AOWLSPT_COMPONENTS_H
#define AOWLSPT_COMPONENTS_H

#include <windows.h>
#include <stdint.h>

/* ---- Il2CppClass / Il2CppObject, per the derivation above ---- */
#define AOWL_COMP_OBJ_KLASS    0x00   /* MEASURED: il2cpp_object_get_class    */
#define AOWL_COMP_KLASS_IMAGE  0x00   /* MEASURED: il2cpp_class_get_image     */
#define AOWL_COMP_KLASS_NAME   0x10   /* INFERRED, validated at every use     */
#define AOWL_COMP_KLASS_NS     0x18   /* MEASURED: il2cpp_class_get_namespace */

/* ---- caps ---- */
#define AOWL_COMP_MAX          64     /* components listed from one object    */
#define AOWL_COMP_NAME_MAX     192    /* bytes copied out of one C string     */
#define AOWL_COMP_FULL_MAX     400    /* "namespace.name" buffer              */

static int32_t aowl_comp_off_klass(void)  { return AOWL_COMP_OBJ_KLASS;   }
static int32_t aowl_comp_off_name(void)   { return AOWL_COMP_KLASS_NAME;  }
static int32_t aowl_comp_off_ns(void)     { return AOWL_COMP_KLASS_NS;    }
static int32_t aowl_comp_max(void)        { return AOWL_COMP_MAX;         }

/* ---- readability, per page, no SEH ----
 *
 * A C string can straddle a page boundary where the next page is not
 * committed, so a single VirtualQuery over the whole span is not enough and a
 * single VirtualQuery at the start is worse. This walks page by page and stops
 * at the first page that is not readable, returning what it could read. A
 * truncated name is an answer; a fault is not. */
static int32_t aowl_comp_page_ok(const void *p) {
    MEMORY_BASIC_INFORMATION mbi;
    DWORD prot;
    if (!p) return 0;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) != sizeof(mbi)) return 0;
    if (mbi.State != MEM_COMMIT) return 0;
    if (mbi.Protect & PAGE_GUARD) return 0;
    prot = mbi.Protect & 0xFFu;
    if (prot == PAGE_NOACCESS) return 0;
    return (prot == PAGE_READONLY || prot == PAGE_READWRITE ||
            prot == PAGE_WRITECOPY || prot == PAGE_EXECUTE_READ ||
            prot == PAGE_EXECUTE_READWRITE || prot == PAGE_EXECUTE_WRITECOPY)
           ? 1 : 0;
}

/* Copy a NUL-terminated ASCII string, capped, page-checked, never faulting.
 * Returns the number of bytes written, or -1 when the first page is not
 * readable. `out` is always NUL-terminated when the return is >= 0.
 *
 * REJECTS NON-PRINTABLE BYTES. A wrong pointer usually lands on binary, and
 * binary rendered as text is the kind of plausible garbage that gets believed;
 * stopping at the first byte outside 0x20..0x7E turns that into a short or
 * empty string that the caller's index check then rejects outright. */
static int32_t aowl_comp_cstr(const void *p, char *out, int32_t cap) {
    const unsigned char *s = (const unsigned char *)p;
    int32_t n = 0;
    if (!out || cap <= 0) return -1;
    out[0] = 0;
    if (!s) return -1;
    if (!aowl_comp_page_ok(s)) return -1;
    while (n < cap - 1) {
        unsigned char c;
        /* re-check whenever the next byte begins a new page */
        if ((((uintptr_t)(s + n)) & 0xFFFu) == 0u && n > 0) {
            if (!aowl_comp_page_ok(s + n)) break;
        }
        c = s[n];
        if (c == 0) break;
        if (c < 0x20u || c > 0x7Eu) break;
        out[n] = (char)c;
        n++;
    }
    out[n] = 0;
    return n;
}

/* "namespace.name" for an Il2CppClass*, built from the two raw reads.
 * Returns 1 on success. `ns_len == 0` is normal and correct -- nested types
 * and the global namespace both have an empty namespace in metadata, and
 * `tools/il2cpp_nameindex.py` builds its keys the same way, so the two agree
 * by construction rather than by luck. */
static int32_t aowl_comp_klass_fullname(const void *klass, char *out, int32_t cap) {
    char ns[AOWL_COMP_NAME_MAX];
    char nm[AOWL_COMP_NAME_MAX];
    const void *pns;
    const void *pnm;
    int32_t a, b, i, at = 0;

    if (!out || cap <= 1) return 0;
    out[0] = 0;
    if (!klass) return 0;
    /* the two pointer slots must themselves be readable */
    if (!aowl_comp_page_ok((const unsigned char *)klass + AOWL_COMP_KLASS_NAME)) return 0;
    if (!aowl_comp_page_ok((const unsigned char *)klass + AOWL_COMP_KLASS_NS)) return 0;
    pnm = *(const void * const *)((const unsigned char *)klass + AOWL_COMP_KLASS_NAME);
    pns = *(const void * const *)((const unsigned char *)klass + AOWL_COMP_KLASS_NS);

    b = aowl_comp_cstr(pnm, nm, AOWL_COMP_NAME_MAX);
    if (b <= 0) return 0;                 /* no name -> no answer, ever */
    a = aowl_comp_cstr(pns, ns, AOWL_COMP_NAME_MAX);
    if (a < 0) a = 0;

    for (i = 0; i < a && at < cap - 2; i++) out[at++] = ns[i];
    if (a > 0 && at < cap - 2) out[at++] = '.';
    for (i = 0; i < b && at < cap - 1; i++) out[at++] = nm[i];
    out[at] = 0;
    return at > 0 ? 1 : 0;
}

/* ---- the offline type table, reached through the existing name index ----
 *
 * `aowlspt_nameindex.h` already owns the file, the build stamp and the
 * binary search; type keys were added to the SAME index rather than a second
 * file, so there is one stamp to be stale and one artifact to deploy. */
static uint32_t aowl_comp_type_rva(const char *full) {
    char key[AOWL_COMP_FULL_MAX + 8];
    int32_t n = 0;
    if (!full) return 0;
    while (n < AOWL_COMP_FULL_MAX && full[n]) { key[n] = full[n]; n++; }
    if (full[n]) return 0;
    key[n++] = ':'; key[n++] = ':'; key[n++] = '@';
    key[n++] = 't'; key[n++] = 'y'; key[n++] = 'p'; key[n++] = 'e';
    key[n] = 0;
    return aowl_nameidx_lookup(key, 0);
}

static int32_t aowl_comp_is_known_type(const char *full) {
    char key[AOWL_COMP_FULL_MAX + 8];
    int32_t n = 0;
    if (!full) return 0;
    while (n < AOWL_COMP_FULL_MAX && full[n]) { key[n] = full[n]; n++; }
    if (full[n]) return 0;
    key[n++] = ':'; key[n++] = ':'; key[n++] = '@';
    key[n++] = 'n'; key[n++] = 'a'; key[n++] = 'm'; key[n++] = 'e';
    key[n] = 0;
    return aowl_nameidx_lookup(key, 0) != 0 ? 1 : 0;
}

/* A DATA address from an RVA. Deliberately NOT `aowl_insp_code`, which
 * requires the page to be EXECUTABLE -- correct for a call target and wrong
 * here, because a static `Il2CppType` lives in `.data`. Feeding a data RVA to
 * the code resolver returns NULL with "points at data, not code", which reads
 * as a bad RVA and is not one. Same bounds discipline, different predicate. */
static void *aowl_comp_data_at(uint64_t rva) {
    HMODULE ga = GetModuleHandleA("GameAssembly.dll");
    unsigned char *p;
    if (!ga) return 0;
    if (rva == 0 || rva > 0x7FFFFFFFu) return 0;
    p = (unsigned char *)ga + rva;
    if (!aowl_comp_page_ok(p)) return 0;
    if (!aowl_comp_page_ok(p + 15)) return 0;
    return (void *)p;
}

/* ---- Nim-facing thin wrappers (one hop each, so a crumb can name it) ---- */
static char aowl_comp_namebuf[AOWL_COMP_FULL_MAX];

static int32_t aowl_comp_name_of(void *klass) {
    aowl_comp_namebuf[0] = 0;
    return aowl_comp_klass_fullname(klass, aowl_comp_namebuf, AOWL_COMP_FULL_MAX);
}
static const char *aowl_comp_name_buf(void) { return aowl_comp_namebuf; }

#endif /* AOWLSPT_COMPONENTS_H */
