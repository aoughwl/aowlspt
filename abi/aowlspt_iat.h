/* aowlspt_iat.h — replacing what one module calls, without touching the code.
 *
 * Two things this project has to do inside the game happen before anything
 * else can run: answering BSG's BattlEye service check
 * (`aowlspt_beguard.h`), and finding out when IL2CPP is actually initialised
 * (`aowlspt_il2cppready.h`). Both run in the DLL constructor, under the loader
 * lock, before the game's main thread has executed an instruction -- and both
 * want to change what one specific module calls, not what the process calls.
 *
 * An import address table is the right instrument for that, and it is the only
 * one available in that position.
 *
 * **It is scoped to one module.** Detouring `QueryServiceStatusEx` or
 * `GetProcAddress` themselves would change the answer for every caller in the
 * process, including our own mods and the CRT. Rewriting one pointer in
 * `UnityPlayer.dll`'s IAT changes it for `UnityPlayer.dll` and nothing else.
 *
 * **It does not involve the loader.** `GetProcAddress` is not safe under the
 * loader lock: on modern Windows many exports are *forwarders*
 * (advapi32's `QueryServiceStatusEx` forwards to sechost.dll), and resolving
 * one can make the loader map a module while we hold its lock. Reading the PE
 * headers of a module that is already mapped, and writing a pointer through
 * `VirtualProtect`, involves the loader not at all.
 *
 * **It does not involve the detour engine.** `aowlspt_detour.h` writes
 * instructions, parks threads and allocates trampolines, none of which belongs
 * in a constructor. It is the right tool the moment there is a running game;
 * it is the wrong tool before there is one.
 *
 * The cost of the scoping is that this only catches calls a module makes
 * *through its import table*. A module that resolves a function by
 * `GetProcAddress` at runtime is unaffected -- which is exactly why
 * `aowlspt_il2cppready.h` patches `GetProcAddress` itself and watches what is
 * asked for, rather than trying to patch `il2cpp_init`, which UnityPlayer
 * looks up dynamically and never imports.
 */

#ifndef AOWLSPT_IAT_H
#define AOWLSPT_IAT_H

#include <windows.h>
#include <stdint.h>

/* One replacement. `name` is the imported symbol, `repl` is what to call
 * instead, and `original` receives what was there so the replacement can call
 * through. `original` is left untouched when the patch does not happen, so a
 * replacement that checks it for NULL cannot call into nothing. */
typedef struct AowlIatPatch {
    const char* name;
    void*       repl;
    void**      original;
} AowlIatPatch;

/* Case-insensitive ASCII compare against a literal. `lstrcmpiA` would do this,
 * but it lives in kernel32's forwarded set and this runs under the loader
 * lock; ten lines of C are cheaper than having to know whether that is safe. */
static int aowl_iat_eq_ci(const char* s, const char* lit) {
    if (!s || !lit) return 0;
    for (;;) {
        char a = *s++, b = *lit++;
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return 0;
        if (a == 0) return 1;
    }
}

/* The last path component, so a module can be recognised however it was
 * spelled: `LoadLibraryW` is given absolute paths as often as bare names. */
static const wchar_t* aowl_iat_basename_w(const wchar_t* p) {
    const wchar_t* last = p;
    if (!p) return NULL;
    for (; *p; p++)
        if (*p == L'\\' || *p == L'/') last = p + 1;
    return last;
}

static int aowl_iat_eq_ci_w(const wchar_t* s, const wchar_t* lit) {
    if (!s || !lit) return 0;
    for (;;) {
        wchar_t a = *s++, b = *lit++;
        if (a >= L'A' && a <= L'Z') a = (wchar_t)(a - L'A' + L'a');
        if (b >= L'A' && b <= L'Z') b = (wchar_t)(b - L'A' + L'a');
        if (a != b) return 0;
        if (a == 0) return 1;
    }
}

/* Write one pointer. Returns 1 if this call changed it, 0 otherwise --
 * including when it was already ours, so arming twice cannot double-count and
 * cannot capture our own replacement as the "original", which would build a
 * loop that calls itself forever. */
static int aowl_iat_swap(void** slot, void* repl, void** original) {
    DWORD old = 0;
    if (!slot || !repl) return 0;
    if (*slot == repl) return 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old)) return 0;
    if (original) *original = *slot;
    *slot = repl;
    VirtualProtect(slot, sizeof(void*), old, &old);
    return 1;
}

/* Walk `mod`'s import descriptors and apply every patch that matches by name.
 * Returns how many slots were changed; `looked`, if given, receives how many
 * named imports were examined, which is what distinguishes "this module has no
 * such import" from "this module's imports were never read".
 *
 * Imports by ordinal are skipped rather than guessed at: the high bit of a
 * thunk's `u1.Ordinal` marks one and it carries no name to match. A descriptor
 * with no `OriginalFirstThunk` is skipped for the same reason -- by the time
 * this runs the loader has overwritten `FirstThunk` with addresses, so there
 * are no names left in it to match against. Both cases come out of here as a
 * lower return value, which is a report, not a wrong patch. */
static int aowl_iat_patch(HMODULE mod, const AowlIatPatch* patches, int n,
                          int* looked) {
    IMAGE_DOS_HEADER* dos;
    IMAGE_NT_HEADERS* nt;
    const IMAGE_DATA_DIRECTORY* dir;
    IMAGE_IMPORT_DESCRIPTOR* imp;
    BYTE* base = (BYTE*)mod;
    int patched = 0;

    if (!mod || !patches || n <= 0) return 0;
    dos = (IMAGE_DOS_HEADER*)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS*)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;

    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir->VirtualAddress == 0 || dir->Size == 0) return 0;

    imp = (IMAGE_IMPORT_DESCRIPTOR*)(base + dir->VirtualAddress);
    for (; imp->Name != 0; imp++) {
        IMAGE_THUNK_DATA* name;
        IMAGE_THUNK_DATA* addr;
        if (imp->OriginalFirstThunk == 0) continue;
        name = (IMAGE_THUNK_DATA*)(base + imp->OriginalFirstThunk);
        addr = (IMAGE_THUNK_DATA*)(base + imp->FirstThunk);
        for (; name->u1.AddressOfData != 0; name++, addr++) {
            IMAGE_IMPORT_BY_NAME* n2;
            const char* fn;
            int i;
            if (name->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
            n2 = (IMAGE_IMPORT_BY_NAME*)(base + name->u1.AddressOfData);
            fn = (const char*)n2->Name;
            if (looked) (*looked)++;
            for (i = 0; i < n; i++) {
                if (aowl_iat_eq_ci(fn, patches[i].name)) {
                    patched += aowl_iat_swap((void**)&addr->u1.Function,
                                             patches[i].repl,
                                             patches[i].original);
                    break;
                }
            }
        }
    }
    return patched;
}

#endif /* AOWLSPT_IAT_H */
