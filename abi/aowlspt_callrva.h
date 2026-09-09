/* aowlspt_callrva.h -- calling a game method AT A STATIC RVA, from a mod.
 *
 * WHY THIS EXISTS
 * ===============
 * Our mods can read the game and cannot call it. Every "it declines" in the
 * registry traces to one missing capability: there is no supported way for a
 * mod to invoke a method whose address we know statically.
 *
 * `aowlspt_fast.h` already solves the hard half -- 189 generated cases that
 * cover every register shape Win64 can present -- but its only entry is
 * `bindMethod`, which resolves BY NAME through the runtime. And fact #145 is
 * that a by-NAME route is fatal the moment it is USED: calling
 * `CameraManager::get_Instance` by name, binding `Physics::Raycast` by name and
 * patching `AddActivePLayer` by name each killed the client instantly and
 * silently. Resolving ~70 names is harmless; using one is not.
 *
 * So the call path a mod needs is: an RVA it already has, byte-verified against
 * the bytes that RVA is DECLARED to start with, dispatched through the shape
 * table that already exists.
 *
 * WHAT IS MEASURED HERE AND WHAT IS ASSERTED
 * ==========================================
 * The by-value aggregate convention used to be the one guess in this project.
 * `mods/sain/client/live.nim` said so in `shapedWhy`: it ASSERTED the Win64
 * rule that an aggregate not of size 1/2/4/8 passes by hidden pointer, and had
 * never proved it against a real callee.
 *
 * It is now MEASURED, from the bytes of three unrelated methods on this build
 * (`tools/il2cpp_resolve.py <GameAssembly.dll> <metadata> bytes <RVA> 32`).
 * These are the callee's own instructions, so they are not an inference about
 * the convention -- they ARE the convention, as compiled:
 *
 *   UnityEngine.Vector3::Dot(Vector3 lhs, Vector3 rhs) -> float   @0x5297BF0
 *     66 90              nop
 *     F3 0F 10 41 04     movss xmm0, [rcx+4]     <- lhs.y  THROUGH RCX
 *     F3 0F 59 42 04     mulss xmm0, [rdx+4]     <- rhs.y  THROUGH RDX
 *     F3 0F 10 09        movss xmm1, [rcx]       <- lhs.x
 *     F3 0F 59 0A        mulss xmm1, [rdx]       <- rhs.x
 *     F3 0F 10 51 08     movss xmm2, [rcx+8]     <- lhs.z
 *     F3 0F 59 52 08     mulss xmm2, [rdx+8]     <- rhs.z
 *
 *   A by-value `Vector3` argument arrives as a POINTER in the ordinary
 *   integer-class register for its position. The callee dereferences RCX and
 *   RDX at +0/+4/+8. It is not a guess and it never was a coin flip; it simply
 *   had never been read. The same bytes independently confirm the unboxed
 *   Vector3 layout x@0 y@4 z@8, and that a static method has no `this`, so the
 *   trailing MethodInfo* here is R8.
 *
 *   UnityEngine.Vector3::Cross(Vector3 lhs, Vector3 rhs) -> Vector3 @0x5297A60
 *     F3 0F 10 5A 04     movss xmm3, [rdx+4]     <- lhs is RDX, not RCX
 *     F3 0F 10 42 08     movss xmm0, [rdx+8]
 *     F3 41 0F 59 40 04  mulss xmm0, [r8+4]      <- rhs is R8
 *     F3 41 0F 59 58 08  mulss xmm3, [r8+8]
 *
 *   The arguments have SHIFTED ONE REGISTER RIGHT versus `Dot`, and the only
 *   difference between the two signatures is that this one returns a 12-byte
 *   struct. So RCX is the hidden return buffer: for a static method returning
 *   an aggregate wider than 8 bytes the shape is
 *       RCX = retbuf, RDX = arg0, R8 = arg1, R9 = MethodInfo*.
 *
 *   UnityEngine.Camera::WorldToScreenPoint(Vector3) -> Vector3    @0x525F940
 *     48 89 5C 24 08     mov [rsp+8], rbx
 *     57                 push rdi
 *     48 83 EC 40        sub rsp, 0x40
 *     F2 41 0F 10 00     movsd xmm0, [r8]        <- the ARGUMENT, through R8
 *     33 C0              xor eax, eax
 *     48 89 01           mov [rcx], rax          <- writes the RETBUF, RCX
 *     48 8B FA           mov rdi, rdx            <- `this`, RDX
 *     89 41 08           mov [rcx+8], eax
 *     48 8B D9           mov rbx, rcx
 *     41 8B 40 08        mov eax, [r8+8]         <- argument .z, through R8
 *
 *   The INSTANCE form of the same rule, in one function:
 *       RCX = retbuf, RDX = this, R8 = arg0, R9 = MethodInfo*.
 *   Note `movsd [r8]` + `mov eax,[r8+8]` = a 12-byte read in 8+4, which is
 *   what a by-hidden-pointer Vector3 looks like and what a by-value one in a
 *   register could not possibly look like.
 *
 *   UnityEngine.Physics::Raycast(Vector3 origin, Vector3 dir, float maxDist)
 *   -> bool                                                       @0x5328830
 *     48 8B DA           mov rbx, rdx            <- dir, a POINTER
 *     0F 29 74 24 60     movaps [rsp+0x60], xmm6
 *     48 8B F9           mov rdi, rcx            <- origin, a POINTER
 *     0F 28 F2           movaps xmm6, xmm2       <- maxDistance, XMM2
 *
 *   The float lands in XMM2 -- the register for POSITION 2 -- while positions
 *   0 and 1 consume RCX and RDX as pointers. That is exactly the model
 *   `aowlspt_fast.h` already implements: register class is chosen per slot by
 *   a mask, and the slot INDEX picks the register in both files. Two by-value
 *   Vector3s in one call are therefore two pointer slots and need no new
 *   machinery at all -- only two buffers, which is what the arena below is.
 *
 * MEASURED SINCE: 8 BYTES GOES IN THE REGISTER
 * --------------------------------------------
 * The 1/2/4/8-byte case -- the one Win64 passes IN the register rather than by
 * pointer -- used to be refused wholesale as unproven. The 8-byte half of it
 * is now measured, from `UnityEngine.Vector2::Dot(Vector2,Vector2)`@0x529BB60,
 * whose entire body spills RCX and RDX to the stack and reads the two floats
 * out of the SPILLED BYTES without ever dereferencing either register. The
 * bytes are quoted in full at `aowl_crva_agg_class` below, and the live check
 * is `Dot((1,2),(3,4)) == 11.0` exactly.
 *
 * 1, 2 and 4 bytes stay REFUSED. The same ABI rule covers them, and that is
 * precisely the extrapolation that had 8 bytes filed as unknowable while the
 * answer sat in a callee we could already read. Nothing needs them yet;
 * whatever needs one first should measure it, not inherit this sentence.
 *
 * MEASURED SINCE: THE STACK, NOT JUST THE REGISTERS
 * -------------------------------------------------
 * A call was capped at five slots and a wider shape was refused rather than
 * spilled, which blocked every 8- and 9-slot method. `aowlspt_fast.h` now
 * emits stack cases up to twelve slots. Shadow-space size, stack-slot stride
 * and argument order were read off `UnityEngine.Matrix4x4::Ortho`@0x5294C30,
 * which takes three of its six floats on the stack; see the header of
 * `tools/gen_fast_table.py` for the three `movss` instructions that fix all
 * three numbers. Nothing here writes assembly: every case is a C call through
 * a full prototype, so the compiler owns alignment and cleanup.
 *
 * SAFETY
 * ======
 * Everything a live path must satisfy, satisfied here rather than in each mod:
 *
 *   1. 16-byte prologue byte-verify, against a CAPTURE-ONCE SNAPSHOT and never
 *      against live memory, so a second feature detouring the same function
 *      does not make this one self-reject and blame the game build.
 *   2. VirtualQuery on every hop: the code page, and every argument buffer.
 *   3. ONE guard around the whole call, and it REFUSES TO ARM if a guard is
 *      already armed on this thread rather than nesting -- nesting disarms the
 *      outer one, which removes protection instead of adding it.
 *   4. No iteration that is not capped.
 *   5/6. The mod owns the flag; `aowl_crva_fault_count` is here so a mod can
 *      self-disable after N faults without inventing its own counter.
 *   7. The argument arena is static and thread-local: no allocation per call,
 *      managed or otherwise.
 *   8. Nothing is written anywhere except into the arena this file owns.
 *
 * WHAT THIS FILE DELIBERATELY WILL NOT DO
 * =======================================
 * It will not resolve a NAME. Not one. That is fact #145 and it is also the
 * job of the offline symbol table being built separately -- see
 * `aowl_crva_target` below for the shape this consumes when that lands.
 *
 * It will not DETOUR anything. Calling a shared RVA is fine (it is correct
 * code for the receiver passed); detouring one is a write with unbounded blast
 * radius, and two detours on one function overwrite each other's trampoline.
 * This header only ever reads the code page.
 */

#ifndef AOWLSPT_CALLRVA_H
#define AOWLSPT_CALLRVA_H

#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <setjmp.h>

#include "aowlspt_shim.h"   /* aowl_is_readable, and the shim guard flag we refuse to nest inside */
#include "aowlspt_fast.h"   /* AowlFastSlot + the 189-case shape dispatcher */

#define AOWL_CRVA_SIG_BYTES  16
#define AOWL_CRVA_SNAP_ROWS  128

/* Arena: fixed, thread-local, 16-byte aligned. Sixteen cells is more than the
 * widest call this dispatcher can make (twelve slots, of which at most eleven
 * could be a buffer, plus a return buffer), and a request outside the range
 * returns NULL rather than wrapping onto another argument's storage. It was
 * eight when a call was capped at five slots; it moved with the cap, because
 * an arena narrower than the slot count is a silent overlap of two arguments.
 * 64 bytes per cell holds every aggregate we have measured -- Vector3 is 12,
 * the unboxed NavMeshHit payload is 36, and Matrix4x4 is exactly 64 (measured:
 * boxed m00@0x10 .. m33@0x4c, so a 64-byte unboxed payload). */
#define AOWL_CRVA_ARENA_SLOTS 16
#define AOWL_CRVA_ARENA_BYTES 64

/* ------------------------------------------------------------------ *
 * Verdicts. Three outcomes, never two: a target either verified, or was
 * refused for a NAMED reason, or could not be looked at. "Could not look" is
 * never folded into "fine".
 * ------------------------------------------------------------------ */
#define AOWL_CRVA_OK            0
#define AOWL_CRVA_NO_MODULE     1  /* GameAssembly.dll is not loaded        */
#define AOWL_CRVA_OUT_OF_IMAGE  2  /* RVA is past the end of the image      */
#define AOWL_CRVA_NOT_CODE      3  /* not committed, or not executable      */
#define AOWL_CRVA_WRONG_SECTION 4  /* not in `il2cpp` (generated code lives
                                    * there, NOT in .text)                  */
#define AOWL_CRVA_DETOURED      5  /* first bytes are a JUMP and no snapshot
                                    * exists: what is here is a TRAMPOLINE,
                                    * not the function. A hook-order problem,
                                    * not a bad RVA. callrva.nim then asks
                                    * the HOST for ITS snapshot (see the
                                    * snapshot note below).                 */
#define AOWL_CRVA_MISMATCH      6  /* snapshot != declared prologue         */
#define AOWL_CRVA_NO_SIG        7  /* the mod declared no prologue at all   */
#define AOWL_CRVA_BAD_ARG       8  /* an argument buffer failed VirtualQuery
                                    * or an aggregate size is unproven      */
#define AOWL_CRVA_GUARD_BUSY    9  /* a guard is already armed on this
                                    * thread; refusing to nest              */
#define AOWL_CRVA_FAULTED      10  /* the call took an access violation and
                                    * the guard caught it                   */
#define AOWL_CRVA_SHAPE        11  /* slot count/mask outside what the fast
                                    * dispatcher can express                */

static const char* aowl_crva_reason(int32_t r) {
    switch (r) {
    case AOWL_CRVA_OK:            return "ok";
    case AOWL_CRVA_NO_MODULE:     return "GameAssembly.dll is not loaded";
    case AOWL_CRVA_OUT_OF_IMAGE:  return "that RVA is outside the image";
    case AOWL_CRVA_NOT_CODE:      return "not committed, or not executable";
    case AOWL_CRVA_WRONG_SECTION: return "outside the `il2cpp` section -- generated code lives there, not in .text";
    case AOWL_CRVA_DETOURED:      return "the first bytes are a JUMP: something already detours this function, so this is a TRAMPOLINE and not the function -- a hook-order problem, not a bad RVA";
    case AOWL_CRVA_MISMATCH:      return "the original bytes are not the declared prologue: wrong RVA, or a different game build";
    case AOWL_CRVA_NO_SIG:        return "no prologue was declared; refusing to call an unverified address";
    case AOWL_CRVA_BAD_ARG:       return "an argument buffer is unreadable, or its size is a convention this build has not proved";
    case AOWL_CRVA_GUARD_BUSY:    return "a fault guard is already armed on this thread; refusing to nest one inside it";
    case AOWL_CRVA_FAULTED:       return "the call took an access violation and was caught";
    case AOWL_CRVA_SHAPE:         return "that slot shape is outside what the fast dispatcher expresses";
    default:                      return "refused";
    }
}

/* ------------------------------------------------------------------ *
 * The image, and the `il2cpp` section inside it.
 * ------------------------------------------------------------------ */
static unsigned char* aowl_crva_base_p   = 0;
static uint32_t       aowl_crva_img_size = 0;
static uint32_t       aowl_crva_gen_lo   = 0;   /* `il2cpp` section start */
static uint32_t       aowl_crva_gen_hi   = 0;   /* .. and one past its end */
static int32_t        aowl_crva_scanned  = 0;

static void aowl_crva_scan_sections(void) {
    IMAGE_DOS_HEADER*   dos;
    IMAGE_NT_HEADERS64* nt;
    IMAGE_SECTION_HEADER* sec;
    unsigned i, n;
    HMODULE ga;
    if (aowl_crva_scanned) return;
    aowl_crva_scanned = 1;
    ga = GetModuleHandleA("GameAssembly.dll");
    if (!ga) { aowl_crva_scanned = 0; return; }   /* retry once it loads */
    aowl_crva_base_p = (unsigned char*)ga;
    dos = (IMAGE_DOS_HEADER*)ga;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    nt = (IMAGE_NT_HEADERS64*)((unsigned char*)ga + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    aowl_crva_img_size = nt->OptionalHeader.SizeOfImage;
    sec = IMAGE_FIRST_SECTION(nt);
    n = nt->FileHeader.NumberOfSections;
    if (n > 96) n = 96;                            /* capped, always */
    for (i = 0; i < n; i++) {
        /* Section names are 8 bytes and NOT necessarily NUL-terminated. */
        if (memcmp(sec[i].Name, "il2cpp", 6) == 0) {
            aowl_crva_gen_lo = sec[i].VirtualAddress;
            aowl_crva_gen_hi = sec[i].VirtualAddress + sec[i].Misc.VirtualSize;
            break;
        }
    }
}

static unsigned char* aowl_crva_base(void) {
    aowl_crva_scan_sections();
    return aowl_crva_base_p;
}

/* Resolve an RVA to a code pointer, or NULL with `*why` set. Every branch here
 * refuses; none of them proceeds hopefully. */
static void* aowl_crva_code(uint32_t rva, int32_t* why) {
    unsigned char* p;
    MEMORY_BASIC_INFORMATION mbi;
    *why = AOWL_CRVA_OK;
    aowl_crva_scan_sections();
    if (!aowl_crva_base_p)                  { *why = AOWL_CRVA_NO_MODULE;    return 0; }
    if (aowl_crva_img_size && rva >= aowl_crva_img_size)
                                            { *why = AOWL_CRVA_OUT_OF_IMAGE; return 0; }
    /* The section check is a real filter, not decoration: a stale RVA that
     * lands in .text is a jump into unrelated native code that happens to be
     * executable, so VirtualQuery alone would wave it through. */
    if (aowl_crva_gen_hi &&
        (rva < aowl_crva_gen_lo || rva >= aowl_crva_gen_hi))
                                            { *why = AOWL_CRVA_WRONG_SECTION; return 0; }
    p = aowl_crva_base_p + rva;
    if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) { *why = AOWL_CRVA_NOT_CODE; return 0; }
    if (mbi.State != MEM_COMMIT)                 { *why = AOWL_CRVA_NOT_CODE; return 0; }
    if (!(mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ |
                         PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY))) {
        *why = AOWL_CRVA_NOT_CODE; return 0;
    }
    return (void*)p;
}

/* Does this look like somebody's trampoline rather than a function? */
static int32_t aowl_crva_looks_detoured(const unsigned char* p) {
    if (p[0] == 0xE9) return 1;                       /* jmp rel32          */
    if (p[0] == 0xEB) return 1;                       /* jmp rel8           */
    if (p[0] == 0xFF && p[1] == 0x25) return 1;       /* jmp [rip+disp32]   */
    if (p[0] == 0x48 && p[1] == 0xB8 &&
        p[10] == 0xFF && p[11] == 0xE0) return 1;     /* mov rax,imm64;jmp  */
    return 0;
}

/* ------------------------------------------------------------------ *
 * The prologue SNAPSHOT.
 *
 * Identical in intent and discipline to `abi/aowlspt_prologue.h`, which is a
 * HOST header: it is `static`, so a mod that included it would get its own
 * empty table anyway. The host DOES answer for the real one since 2026-09-05:
 * `call("aowlspt.host::original_bytes", {"rva":"0x.."})` copies a primed
 * row out, and `aowl_crva_t_accept` (callrva.nim) runs this same compare
 * against those bytes when the live first bytes are a JUMP -- see the note
 * on AOWL_CRVA_DETOURED. What makes a mod-local table still
 * correct is the same argument the host header makes: a target's FIRST verify
 * necessarily precedes THIS mod's first use of it, and this file never
 * patches anything, so the only way a snapshot can be poisoned is if some
 * OTHER feature detoured the function before the mod ever looked. That case
 * is not silently accepted -- it is detected by shape and reported as
 * AOWL_CRVA_DETOURED, which names the hook order instead of blaming the RVA.
 * ------------------------------------------------------------------ */
typedef struct {
    uint32_t      rva;
    unsigned char b[AOWL_CRVA_SIG_BYTES];
    int32_t       used;
} AowlCrvaSnap;

static AowlCrvaSnap aowl_crva_snaps[AOWL_CRVA_SNAP_ROWS];
static int32_t      aowl_crva_snap_used = 0;

static AowlCrvaSnap* aowl_crva_snap_find(uint32_t rva) {
    int32_t i;
    for (i = 0; i < aowl_crva_snap_used; i++)
        if (aowl_crva_snaps[i].rva == rva) return &aowl_crva_snaps[i];
    return 0;
}

/* Capture ONCE, and never update. A second capture after a detour landed would
 * record the trampoline and re-introduce the bug the snapshot exists to kill. */
static AowlCrvaSnap* aowl_crva_snap_take(uint32_t rva, const unsigned char* p) {
    AowlCrvaSnap* r = aowl_crva_snap_find(rva);
    if (r) return r;
    if (aowl_crva_snap_used >= AOWL_CRVA_SNAP_ROWS) return 0;
    r = &aowl_crva_snaps[aowl_crva_snap_used++];
    r->rva = rva;
    memcpy(r->b, p, AOWL_CRVA_SIG_BYTES);
    r->used = 1;
    return r;
}

/* ------------------------------------------------------------------ *
 * A target: an RVA plus the bytes it is DECLARED to start with.
 *
 * `owners` is the field the offline symbol table fills in. That table -- name
 * -> unique RVA with an owner count, failing the BUILD on a shared or
 * mismatched target -- is being built separately and is NOT duplicated here.
 * WHAT THIS FILE ASSUMES ABOUT IT, so the assumption is checkable rather than
 * buried:
 *
 *   * it emits a compile-time CONSTANT per symbol: an RVA, the first 16
 *     prologue bytes, and how many methods share that RVA;
 *   * `owners == 1` means unique; `owners > 1` means folded;
 *   * it fails the BUILD, so nothing here needs to fail at run time on a
 *     shared target -- and `owners` is carried anyway so a log line can say
 *     "1 owner" rather than leaving it to be assumed.
 *
 * If it lands with a different shape, the change is to `aowl_crva_target` and
 * to nothing else: no call site names an RVA directly.
 * ------------------------------------------------------------------ */
typedef struct {
    const char*   name;      /* for messages only; NEVER resolved            */
    uint32_t      rva;
    unsigned char sig[AOWL_CRVA_SIG_BYTES];
    int32_t       siglen;
    int32_t       owners;    /* from the offline table; 0 = not stated       */
    void*         fn;        /* filled by verify                             */
    int32_t       why;       /* AOWL_CRVA_*                                  */
    int32_t       verified;
} AowlCrvaTarget;

/* THE VERIFY. Byte-compares the DECLARED prologue against the snapshot of the
 * original bytes. Fails closed on everything. Idempotent: a verified target
 * is not re-read. */
static int32_t aowl_crva_verify(AowlCrvaTarget* t) {
    void* p;
    int32_t why = AOWL_CRVA_OK;
    AowlCrvaSnap* s;
    if (!t) return AOWL_CRVA_BAD_ARG;
    if (t->verified) return t->why;
    if (t->siglen <= 0) { t->why = AOWL_CRVA_NO_SIG; t->verified = 1; return t->why; }
    if (t->siglen > AOWL_CRVA_SIG_BYTES) t->siglen = AOWL_CRVA_SIG_BYTES;
    p = aowl_crva_code(t->rva, &why);
    if (!p) { t->why = why; t->verified = 1; return t->why; }

    s = aowl_crva_snap_find(t->rva);
    if (!s) {
        /* First look at this RVA. If what is here is a jump, we are looking at
         * somebody's trampoline and the original bytes are gone; refuse and
         * SAY SO, rather than recording the trampoline as truth. */
        if (aowl_crva_looks_detoured((const unsigned char*)p)) {
            t->why = AOWL_CRVA_DETOURED; t->verified = 1; return t->why;
        }
        s = aowl_crva_snap_take(t->rva, (const unsigned char*)p);
        if (!s) { t->why = AOWL_CRVA_NOT_CODE; t->verified = 1; return t->why; }
    }
    if (memcmp(s->b, t->sig, (size_t)t->siglen) != 0) {
        t->why = AOWL_CRVA_MISMATCH; t->verified = 1; return t->why;
    }
    t->fn = p;
    t->why = AOWL_CRVA_OK;
    t->verified = 1;
    return AOWL_CRVA_OK;
}

/* ------------------------------------------------------------------ *
 * The argument arena.
 *
 * A by-value aggregate is passed as a pointer to storage the CALLER owns and
 * keeps alive across the call; an `out`/`ref` parameter is the same thing that
 * the callee writes instead of reads. One arena covers both, and being static
 * and thread-local it costs no allocation on any path -- which is rule 7, and
 * matters because the consumers of this are per-bot-per-frame.
 * ------------------------------------------------------------------ */
typedef struct { unsigned char b[AOWL_CRVA_ARENA_BYTES]; } AowlCrvaCell;
static __declspec(align(16)) __thread AowlCrvaCell aowl_crva_cells[AOWL_CRVA_ARENA_SLOTS];

static void* aowl_crva_cell(int32_t i) {
    if (i < 0 || i >= AOWL_CRVA_ARENA_SLOTS) return 0;
    return (void*)aowl_crva_cells[i].b;
}

static void* aowl_crva_cell_zero(int32_t i, int32_t nbytes) {
    void* p;
    if (nbytes < 0 || nbytes > AOWL_CRVA_ARENA_BYTES) return 0;
    p = aowl_crva_cell(i);
    if (!p) return 0;
    memset(p, 0, (size_t)AOWL_CRVA_ARENA_BYTES);
    return p;
}

/* How an aggregate of this size travels, on THIS build. Three answers, and
 * the third is a refusal rather than a default.
 *
 *   AGG_POINTER (>8 bytes)  -- measured by hidden pointer, three times over
 *       (see the header comment). 3, 5, 6, 7 are also not register sizes and
 *       take the same route; no such argument has been measured here, and the
 *       header says so rather than implying it was.
 *
 *   AGG_INREG (exactly 8)   -- MEASURED, and it is the one that was refused
 *       until now. `UnityEngine.Vector2::Dot(Vector2,Vector2) -> float`
 *       @0x529BB60 is two 8-byte by-value aggregates and one owner, and its
 *       whole body is:
 *
 *           48 83 EC 18        sub   rsp, 0x18
 *           48 89 54 24 38     mov   [rsp+0x38], rdx    <- stores RDX AS A VALUE
 *           48 89 0C 24        mov   [rsp+0x00], rcx    <- stores RCX AS A VALUE
 *           F3 0F 10 44 24 3C  movss xmm0, [rsp+0x3c]   <- rhs.y, byte 4 OF THAT VALUE
 *           F3 0F 10 4C 24 38  movss xmm1, [rsp+0x38]   <- rhs.x
 *           F3 0F 59 44 24 04  mulss xmm0, [rsp+0x04]   <- lhs.y
 *           F3 0F 59 0C 24     mulss xmm1, [rsp+0x00]   <- lhs.x
 *           F3 0F 58 C1        addss xmm0, xmm1
 *           48 83 C4 18 C3     add   rsp, 0x18 ; ret
 *
 *       It never DEREFERENCES RCX or RDX. It spills them and reads the float
 *       fields out of the spilled bytes. So an 8-byte aggregate arrives packed
 *       IN the integer-class register for its position, x in the low half.
 *       That is the exact opposite of the >8 case and it is why guessing was
 *       never acceptable. The live check is `checkVec2Dot` in
 *       `aowl/src/aowlspt/callproof.nim`: Dot((1,2),(3,4)) must be exactly 11.
 *
 *   AGG_REFUSE (1, 2, 4)    -- still not measured on this build. The ABI rule
 *       that covers 8 covers these too, but "the rule that covered 8 also
 *       covers 4" is the kind of extrapolation that produced the wrong answer
 *       for 8 in the first place, and nothing in this project needs them yet.
 *       They stay refused, by name, until something measures one. */
#define AOWL_CRVA_AGG_REFUSE  0
#define AOWL_CRVA_AGG_POINTER 1
#define AOWL_CRVA_AGG_INREG   2

static int32_t aowl_crva_agg_class(int32_t size) {
    if (size <= 0) return AOWL_CRVA_AGG_REFUSE;
    if (size == 8) return AOWL_CRVA_AGG_INREG;
    if (size == 1 || size == 2 || size == 4) return AOWL_CRVA_AGG_REFUSE;
    return AOWL_CRVA_AGG_POINTER;
}

/* Kept as its own predicate because "does this go by pointer" and "is this
 * allowed at all" are now two different questions and folding them was how the
 * 8-byte case came to be described as unproven in one place and refused in
 * another. */
static int32_t aowl_crva_agg_by_pointer(int32_t size) {
    return aowl_crva_agg_class(size) == AOWL_CRVA_AGG_POINTER ? 1 : 0;
}

/* Load an 8-byte by-value aggregate as the packed value the register carries.
 * No arena cell: the bytes ARE the argument, so there is nothing to keep alive
 * across the call. Returns 0 and leaves `*out` untouched if the source is not
 * readable -- `aowl_is_readable` on the source is the whole of rule 2 here,
 * and it is not skipped just because eight bytes feels small. */
static int32_t aowl_crva_agg8(const void* src, int64_t* out) {
    int64_t v = 0;
    if (!out) return 0;
    if (!aowl_is_readable((void*)src, 8)) return 0;
    memcpy(&v, src, 8);
    *out = v;
    return 1;
}

/* Stage a by-value aggregate into arena cell `i` and hand back the pointer the
 * call must pass. Returns NULL when the size is one whose convention this
 * build has not proved, or when the source is unreadable. */
static void* aowl_crva_arg_agg(int32_t i, const void* src, int32_t size) {
    void* p;
    /* Only the by-POINTER class stages a cell. An 8-byte aggregate has a
     * proven convention but it is not this one, so it is still NULL here and
     * the nimony side routes it to `aowl_crva_agg8` instead -- refusing here
     * would now be wrong, and quietly staging a cell for it would be worse. */
    if (aowl_crva_agg_class(size) != AOWL_CRVA_AGG_POINTER) return 0;
    if (size > AOWL_CRVA_ARENA_BYTES) return 0;
    if (!aowl_is_readable((void*)src, size)) return 0;
    p = aowl_crva_cell_zero(i, size);
    if (!p) return 0;
    memcpy(p, src, (size_t)size);
    return p;
}

/* An `out`/`ref` buffer: zeroed storage the callee writes through. The same
 * cells, so a caller must not use one index for both. */
static void* aowl_crva_arg_out(int32_t i, int32_t size) {
    if (size <= 0 || size > AOWL_CRVA_ARENA_BYTES) return 0;
    return aowl_crva_cell_zero(i, size);
}

/* Read a float back out of a cell, guarded. `ok` distinguishes "0.0" from
 * "could not look", which is the whole of rule 9b in one out-parameter. */
static float aowl_crva_cell_f32(int32_t i, int32_t off, int32_t* ok) {
    unsigned char* p = (unsigned char*)aowl_crva_cell(i);
    float v = 0.0f;
    *ok = 0;
    if (!p) return 0.0f;
    if (off < 0 || off + 4 > AOWL_CRVA_ARENA_BYTES) return 0.0f;
    memcpy(&v, p + off, 4);
    *ok = 1;
    return v;
}
static int32_t aowl_crva_cell_i32(int32_t i, int32_t off, int32_t* ok) {
    unsigned char* p = (unsigned char*)aowl_crva_cell(i);
    int32_t v = 0;
    *ok = 0;
    if (!p) return 0;
    if (off < 0 || off + 4 > AOWL_CRVA_ARENA_BYTES) return 0;
    memcpy(&v, p + off, 4);
    *ok = 1;
    return v;
}

/* ------------------------------------------------------------------ *
 * The guard.
 *
 * ONE per call body, and it REFUSES TO ARM inside another rather than nesting.
 * `aowlspt_shim.h`'s `aowl_p_p_seh` documents why nesting is fatal: the
 * thread-local `jmp_buf` and `active` flag are single, so an inner guard
 * overwrites the outer one's landing pad and clears its flag on exit --
 * removing protection while looking like it added some. This guard has its own
 * pad and additionally checks the shim's flag, so the two cannot be nested in
 * either order without one of them declining out loud.
 * ------------------------------------------------------------------ */
static __thread jmp_buf aowl_crva_pad;
static __thread int32_t aowl_crva_armed = 0;
static int32_t aowl_crva_faults = 0;

static LONG CALLBACK aowl_crva_veh(PEXCEPTION_POINTERS ep) {
    if (aowl_crva_armed &&
        ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        aowl_crva_armed = 0;
        longjmp(aowl_crva_pad, 1);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static int32_t aowl_crva_fault_count(void) { return aowl_crva_faults; }

/* Guarded dispatch. `out` receives the raw RAX / XMM0 value; the return value
 * is an AOWL_CRVA_* verdict. Separating the two is deliberate: a call that
 * faulted and a call that returned 0 are different answers and this never
 * flattens them into one. */
static int32_t aowl_crva_invoke(AowlCrvaTarget* t, void* mi, int32_t nslots,
                                uint32_t mask, const AowlFastSlot* a,
                                int32_t retclass,   /* 0=int/ptr 1=float 2=double */
                                int64_t* out_g, double* out_f) {
    static volatile LONG installed = 0;
    int32_t v;
    *out_g = 0;
    *out_f = 0.0;
    if (!t) return AOWL_CRVA_BAD_ARG;
    v = aowl_crva_verify(t);
    if (v != AOWL_CRVA_OK) return v;
    if (!t->fn) return AOWL_CRVA_NOT_CODE;
    if (nslots < 0 || nslots > AOWL_FAST_MAX_SLOTS) return AOWL_CRVA_SHAPE;
    /* Refuse to nest -- on our own guard OR on the shim's. */
    if (aowl_crva_armed || aowl_seh_active) return AOWL_CRVA_GUARD_BUSY;

    if (InterlockedCompareExchange(&installed, 1, 0) == 0)
        AddVectoredExceptionHandler(1, aowl_crva_veh);

    aowl_crva_armed = 1;
    if (setjmp(aowl_crva_pad) == 0) {
        if (retclass == 1)
            *out_f = (double)aowl_fast_f(t->fn, mi, nslots, mask, a);
        else if (retclass == 2)
            *out_f = aowl_fast_d(t->fn, mi, nslots, mask, a);
        else
            *out_g = aowl_fast_g(t->fn, mi, nslots, mask, a);
        aowl_crva_armed = 0;
        return AOWL_CRVA_OK;
    }
    aowl_crva_armed = 0;
    aowl_crva_faults++;
    return AOWL_CRVA_FAULTED;
}

#endif /* AOWLSPT_CALLRVA_H */
