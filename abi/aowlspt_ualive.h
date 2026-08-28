/* aowlspt_ualive.h -- THE ONE LIVENESS PREDICATE FOR A UnityEngine.Object.
 *
 * ## The silent failure this removes
 *
 * `Destroy(go)` does NOT free the managed wrapper. It zeroes the native handle
 * inside it -- `UnityEngine.Object.m_CachedPtr` at +0x10 -- and leaves the
 * managed object on the GC heap, fully mapped and fully READABLE. C# hides this
 * behind an overloaded `==` that reports the wrapper as null; native code has
 * no such courtesy.
 *
 * So `aowl_is_readable(obj, 0x20)` returns 1 for a destroyed object, every
 * time. Every `duOk`-style check in this host says YES to a corpse. The read
 * that follows returns a plausible value, and the first icall that follows THAT
 * dereferences a null native handle and dies inside Unity's C++, where no
 * `aowl_p_p_seh` of ours reaches. Fact #182: `duCanvasRootGo` is three managed
 * calls and it is the internal call, not our code, that takes the process down.
 *
 * READABILITY IS NOT LIVENESS. It is also not identity: two different Unity
 * classes both carry `m_CachedPtr` at +0x10, so this predicate says nothing at
 * all about WHAT the object is. It answers one question -- has this wrapper's
 * native side been destroyed -- and callers must not read more into it. That
 * limit is the reason `aowl_unity_alive` refuses to be spelled "ok".
 *
 * ## Why +0x10 and why it is not a guess
 *
 * `UnityEngine.Object` is `{ void* klass; void* monitor; intptr m_CachedPtr; }`
 * -- the standard two-pointer IL2CPP object header then the first instance
 * field. The offset is already relied on and named in `abi/aowlspt_navui.h`
 * (AOWL_NAV_UOBJ_CACHEDPTR) and `abi/aowlspt_widget.h`; this file is the single
 * definition those should defer to, not a fourth copy.
 *
 * ## Safety
 *
 * Every hop is `aowl_is_readable`-gated -- the wrapper itself before the field
 * is read, and then the handle value is checked for the tell-tale shapes of a
 * dead one. No guard is entered here: `aowl_p_p_seh` is NOT re-entrant, and
 * this is called from inside guarded bodies, where a nested guard would DISARM
 * the outer one.
 */
#ifndef AOWLSPT_UALIVE_H
#define AOWLSPT_UALIVE_H

#include <windows.h>
#include <stdint.h>

#define AOWL_UOBJ_CACHEDPTR 0x10   /* UnityEngine.Object.m_CachedPtr */

/* The three answers, because two is how a "could not look" becomes a "yes". */
enum {
    AOWL_ALIVE_NO      = 0,  /* the wrapper is readable and m_CachedPtr is 0:
                              * DESTROYED. Unity's "fake null". */
    AOWL_ALIVE_YES     = 1,  /* readable, and the native handle is plausible  */
    AOWL_ALIVE_UNKNOWN = 2   /* not readable at all, or not an object shape:
                              * INCONCLUSIVE. Never treat as YES. */
};

/* `aowl_is_readable` lives in aowlspt_shim.h, which every includer of this
 * header already has. Declared rather than included so this file adds no
 * include-order constraint. */
static int32_t aowl_is_readable(void *p, int32_t size);

static int32_t aowl_unity_alive_ex(void *obj) {
    uint64_t handle;
    if (!obj) return AOWL_ALIVE_UNKNOWN;      /* a null POINTER is not a
                                               * destroyed object; it is no
                                               * object, and saying so keeps
                                               * the two failures apart. */
    /* The whole header plus the field, in one query: a wrapper that straddles
     * the end of a committed region is not something to read half of. */
    if (!aowl_is_readable(obj, AOWL_UOBJ_CACHEDPTR + 8))
        return AOWL_ALIVE_UNKNOWN;
    /* klass must at least be a pointer-shaped, mapped value, or this is not an
     * il2cpp object and m_CachedPtr means nothing here. */
    {
        uint64_t klass = *(uint64_t *)obj;
        if (klass < 0x10000ull || klass >= 0x7FFFFFFFFFFFull)
            return AOWL_ALIVE_UNKNOWN;
    }
    handle = *(uint64_t *)((unsigned char *)obj + AOWL_UOBJ_CACHEDPTR);
    if (handle == 0ull) return AOWL_ALIVE_NO;         /* THE FAKE NULL */
    /* A non-zero handle that is not a plausible user-space address is not a
     * live native object either -- it is garbage, and calling through it is the
     * same crash by a different route. */
    if (handle < 0x10000ull || handle >= 0x7FFFFFFFFFFFull)
        return AOWL_ALIVE_NO;
    return AOWL_ALIVE_YES;
}

/* The predicate for a call site that only wants a yes/no. UNKNOWN reads as NO,
 * which is the safe collapse: "I could not look" must never open a gate.
 * Call sites that need to TELL the two apart -- to log INCONCLUSIVE rather than
 * FAIL, per CLAUDE.md 9b -- use `aowl_unity_alive_ex`. */
static int32_t aowl_unity_alive(void *obj) {
    return aowl_unity_alive_ex(obj) == AOWL_ALIVE_YES ? 1 : 0;
}

static const char *aowl_unity_alive_name(int32_t k) {
    switch (k) {
    case AOWL_ALIVE_NO:  return "DESTROYED (m_CachedPtr@0x10 is zero -- this "
                                "is Unity's fake null: the managed wrapper is "
                                "still readable, the native object is gone, "
                                "and the next internal call through it dies "
                                "inside Unity's C++ where no guard reaches)";
    case AOWL_ALIVE_YES: return "LIVE (m_CachedPtr@0x10 holds a plausible "
                                "native handle -- which says nothing about "
                                "WHAT the object is)";
    default:             return "INCONCLUSIVE (the wrapper could not be read, "
                                "or does not have an il2cpp object shape -- "
                                "this is not a yes)";
    }
}

#endif /* AOWLSPT_UALIVE_H */
