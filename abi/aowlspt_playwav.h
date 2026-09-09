/* aowlspt_playwav.h — fire-and-forget .wav playback, and nothing more.
 *
 * WHAT THIS IS. `PlaySoundW(path, NULL, SND_FILENAME|SND_ASYNC|SND_NODEFAULT)`
 * behind a dynamic load of `winmm.dll`, a path check, and an honest refusal.
 * That is the entire feature. It exists because the host had no way to make a
 * sound at all, and a mod that wants to play one line of speech should not
 * have to emit its own C and its own DLL loader to do it.
 *
 * NON-SPATIAL BY DESIGN, and this must not be discovered later. `PlaySoundW`
 * mixes into the process's default waveform-output device at whatever level
 * that device sits. It has no position, no distance attenuation, no occlusion
 * and no relationship to the game's audio listener; a sound played this way is
 * heard identically wherever the player is standing. SPATIAL playback means
 * driving a real Unity `AudioSource` through byte-verified RVAs, which is a
 * separate and much larger step — the RVA groundwork for it is in
 * `docs/VOICE_RVA.md`, and `abi/aowlspt_audioray.h` is the other half of that
 * story. Do not extend this file in that direction; it is the wrong shape for
 * it.
 *
 * VOLUME IS IGNORED, deliberately, and the verb says so in its answer rather
 * than accepting the parameter and silently dropping it. The only knob winmm
 * offers without an open stream is `waveOutSetVolume`, which sets the volume of
 * the OUTPUT DEVICE — not of our sound. On a shared device that is the game's
 * volume, the voice-chat volume and every other application's volume, changed
 * globally and left changed if we crash between setting and restoring it. That
 * is not "trivially safe", so it is not done. Per-sound volume needs a real
 * mixer (an `AudioSource`, or vaudio), i.e. the same later step as spatial.
 *
 * WHY DYNAMIC LOAD. The IL2CPP host links nothing (`buildIl2CppHost` in
 * `tools/aowl.nim` passes no `--passL` at all). An import of `winmm.dll` would
 * make it a load-time dependency of a DLL injected into a process that is
 * mid-startup, where a failed import is a silent load failure with no log
 * line. Resolved by hand, a missing winmm is a printable refusal.
 *
 * THREADING. `SND_ASYNC` returns immediately; winmm does the playback on its
 * own thread. Nothing here blocks, nothing here touches game memory, no
 * il2cpp export is called and no pointer from the game is dereferenced — so,
 * exactly as in `aowlspt_hostnet.h`, there is no `aowl_p_p_seh` here and that
 * is correct rather than an omission: the guard is for faulting reads of a
 * moving managed heap, and it is not re-entrant, so a guard here nested inside
 * a caller's guard would DISARM the caller's.
 *
 * THE ROOT ALLOWLIST IS NOT ENFORCED HERE. It is enforced on the Nim side
 * (`hostnet.nim`), where `%TEMP%` expansion and case-insensitive prefix
 * matching are three lines instead of thirty. This file checks only that the
 * file exists and that winmm answered.
 */

#ifndef AOWLSPT_PLAYWAV_H
#define AOWLSPT_PLAYWAV_H

#include <windows.h>
#include <stdint.h>

#define AOWL_PW_PATH_CAP 1024

typedef BOOL (WINAPI *AowlPwPlaySoundW)(LPCWSTR, HMODULE, DWORD);

static struct {
    HMODULE          lib;
    AowlPwPlaySoundW play;
    int32_t          tried;
    int32_t          ok;
    int64_t          played;
    int64_t          refused;
} g_pw;

/* One-time init that is correct with two threads in it. The naive
 * `if (tried) return ok; tried = 1; ...` shape is not: a second caller reads
 * `tried == 1` while the first is inside `LoadLibraryA` and reports "winmm.dll
 * is not loadable", which is a confidently wrong diagnosis of an intermittent
 * failure. The identical bug was MEASURED in `aowlspt_hostnet.h` on
 * 2026-09-06 by `tools/test_hosthttp.py`; this file had it too and it is
 * fixed here for the same reason, not by analogy.
 *
 * `state`: 0 untouched, 2 a thread is resolving, 1 resolved (`ok` is final). */
static volatile LONG g_pwState;

static int32_t aowl_pw_api(void) {
    for (;;) {
        LONG st = InterlockedCompareExchange(&g_pwState, 2, 0);
        if (st == 1) return g_pw.ok;
        if (st == 2) { Sleep(0); continue; }
        /* st == 0 and we now own the resolve. */
        g_pw.lib = LoadLibraryA("winmm.dll");
        if (g_pw.lib)
            g_pw.play = (AowlPwPlaySoundW)(void*)GetProcAddress(g_pw.lib, "PlaySoundW");
        g_pw.ok = g_pw.play ? 1 : 0;
        g_pw.tried = 1;
        InterlockedExchange(&g_pwState, 1);
        return g_pw.ok;
    }
}

static void aowl_pw_say(char* why, int32_t cap, const char* s) {
    int32_t i = 0;
    if (!why || cap <= 0) return;
    while (i < cap - 1 && s[i]) { why[i] = s[i]; i++; }
    why[i] = 0;
}

/* Play `path` (UTF-8, widened here) asynchronously. Returns 1 played, 0
 * refused with `why` filled in. Always answers. */
static int32_t aowl_pw_play_path(const char* path, char* why, int32_t whyCap) {
    wchar_t w[AOWL_PW_PATH_CAP];
    int32_t n;
    DWORD attr;

    if (why && whyCap > 0) why[0] = 0;
    if (!path || !path[0]) { aowl_pw_say(why, whyCap, "no path was given"); g_pw.refused++; return 0; }

    /* UTF-8 -> UTF-16 through the OS, not a byte widen: a path under a
     * profile directory with a non-ASCII name is ordinary, and a byte widen
     * would turn it into a file that does not exist — which would then be
     * reported as "the file is missing", a confidently wrong answer. */
    n = (int32_t)MultiByteToWideChar(CP_UTF8, 0, path, -1, w, AOWL_PW_PATH_CAP);
    if (n <= 0) {
        aowl_pw_say(why, whyCap, "the path is not valid UTF-8, or is longer than 1023 characters");
        g_pw.refused++;
        return 0;
    }

    attr = GetFileAttributesW(w);
    if (attr == INVALID_FILE_ATTRIBUTES) {
        aowl_pw_say(why, whyCap, "no such file");
        g_pw.refused++;
        return 0;
    }
    if (attr & FILE_ATTRIBUTE_DIRECTORY) {
        aowl_pw_say(why, whyCap, "that path is a directory, not a .wav file");
        g_pw.refused++;
        return 0;
    }
    if (!aowl_pw_api()) {
        aowl_pw_say(why, whyCap, "winmm.dll is not loadable, or has no PlaySoundW");
        g_pw.refused++;
        return 0;
    }
    /* 0x00020000 SND_FILENAME | 0x0001 SND_ASYNC | 0x0002 SND_NODEFAULT.
     * NODEFAULT matters: without it a file winmm cannot decode plays the
     * system "ding" instead, and the caller is told it succeeded. */
    if (!g_pw.play(w, NULL, 0x00020000 | 0x0001 | 0x0002)) {
        aowl_pw_say(why, whyCap,
                    "PlaySoundW refused the file (winmm plays PCM .wav only; "
                    "an mp3/ogg or a compressed wav is not decodable here)");
        g_pw.refused++;
        return 0;
    }
    g_pw.played++;
    return 1;
}

/* Stop whatever is playing. Same call with a NULL path, which is winmm's
 * documented way of doing it. Harmless when nothing is playing. */
static int32_t aowl_pw_stop(void) {
    if (!aowl_pw_api()) return 0;
    return g_pw.play(NULL, NULL, 0x0001 | 0x0002) ? 1 : 0;
}

/* `%TEMP%` -> `C:\Users\...\AppData\Local\Temp`, through the OS. The root
 * allowlist ships with `%TEMP%` in it, and a root that is never expanded is a
 * root that matches nothing — a check that cannot fail in the wrong
 * direction. Returns the length written, or 0. */
static int32_t aowl_pw_expand(const char* s, char* out, int32_t cap) {
    DWORD n;
    if (!out || cap <= 0) return 0;
    out[0] = 0;
    if (!s || !s[0]) return 0;
    n = ExpandEnvironmentStringsA(s, out, (DWORD)cap);
    if (n == 0 || (int32_t)n > cap) { out[0] = 0; return 0; }
    return (int32_t)(n > 0 ? n - 1 : 0);
}

static int64_t aowl_pw_played(void)  { return g_pw.played; }
static int64_t aowl_pw_refused(void) { return g_pw.refused; }

#endif /* AOWLSPT_PLAYWAV_H */
