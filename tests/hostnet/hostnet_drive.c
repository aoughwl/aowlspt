/* hostnet_drive.c -- drives the REAL `abi/aowlspt_hostnet.h` and
 * `abi/aowlspt_playwav.h` against a real local HTTP server.
 *
 * WHY THIS SHAPE. `tools/hostharness.nim` and `tests/mockil2cpp` exercise the
 * host DLL's IL2CPP surface; neither can reach `aowlspt_nim_call`'s verb
 * dispatch without the runtime, and building the whole host DLL to test a
 * transport is a 12-22 minute loop. Both headers are self-contained (Win32 +
 * libc, `static` functions, no il2cpp, no game memory), so the code that
 * ACTUALLY decides "allowed / refused / capped / completed" can be compiled
 * and executed on its own. That is the difference between testing the rules
 * and testing a copy of the rules.
 *
 * The Nim layer on top (`host/Aowlspt.Host.Il2Cpp/hostnet.nim`) is NOT covered
 * here -- `tools/test_hosthttp.py` says so out loud rather than letting a
 * green run imply it.
 *
 * Usage: hostnet_drive.exe <case> <port> [arg...]   -- prints one line per
 * observation, prefixed `OUT `, and exits 0. The Python side asserts on those
 * lines; this program never decides a verdict.
 */

#include <stdio.h>
#include "aowlspt_hostnet.h"
#include "aowlspt_playwav.h"

static void wait_done(const char* id, int budgetMs) {
    int waited = 0;
    char idBuf[AOWL_HN_ID_CAP];
    (void)id;
    while (waited < budgetMs) {
        if (aowl_hn_take_done(idBuf, sizeof(idBuf))) return;
        Sleep(20);
        waited += 20;
    }
}

static void report(const char* tag, const char* id) {
    char body[65536];
    char err[AOWL_HN_ERR_CAP];
    int32_t status = 0, ms = 0, blen = 0;
    int32_t rc = aowl_hn_result(id, body, (int32_t)sizeof(body), &status, &ms,
                                err, (int32_t)sizeof(err), &blen);
    printf("OUT %s rc=%d status=%d bytes=%d err=%s body=%s\n",
           tag, (int)rc, (int)status, (int)blen, err, body);
}

int main(int argc, char** argv) {
    const char* kase = argc > 1 ? argv[1] : "";
    int port = argc > 2 ? atoi(argv[2]) : 0;
    char url[512];
    char why[512];

    if (!strcmp(kase, "allowed_get")) {
        aowl_hn_configure(1, 4, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/hello", port);
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("a1", "GET", url, NULL, 0, 5000, why, sizeof(why)), why);
        wait_done("a1", 10000);
        report("a1", "a1");
        return 0;
    }
    if (!strcmp(kase, "disallowed_host")) {
        aowl_hn_configure(1, 4, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        /* `localhost` resolves to the SAME server. If the allowlist were
         * matched on the resolved address, or not matched at all, this would
         * succeed -- which is exactly the negative control the allowlist
         * needs. */
        sprintf(url, "http://localhost:%d/hello", port);
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("b1", "GET", url, NULL, 0, 5000, why, sizeof(why)), why);
        return 0;
    }
    if (!strcmp(kase, "https_refused")) {
        aowl_hn_configure(1, 4, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "https://127.0.0.1:%d/hello", port);
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("c1", "GET", url, NULL, 0, 5000, why, sizeof(why)), why);
        return 0;
    }
    if (!strcmp(kase, "flag_off")) {
        aowl_hn_configure(0, 4, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/hello", port);
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("d1", "GET", url, NULL, 0, 5000, why, sizeof(why)), why);
        return 0;
    }
    if (!strcmp(kase, "req_body_over_cap")) {
        /* maxBody floors at 4096, so ask for the floor and post 8 KiB. */
        static char big[8192];
        memset(big, 'x', sizeof(big));
        aowl_hn_configure(1, 4, 4096);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/echo", port);
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("e1", "POST", url, big, (int32_t)sizeof(big),
                                   5000, why, sizeof(why)), why);
        /* Positive control in the same run: a body UNDER the cap on the same
         * configuration must be accepted, or "refused" proves nothing. */
        printf("OUT control_submit=%d why=%s\n",
               (int)aowl_hn_submit("e2", "POST", url, "hi", 2, 5000, why, sizeof(why)), why);
        wait_done("e2", 10000);
        report("e2", "e2");
        return 0;
    }
    if (!strcmp(kase, "resp_body_over_cap")) {
        aowl_hn_configure(1, 4, 4096);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/big", port);   /* server sends 64 KiB */
        printf("OUT submit=%d why=%s\n",
               (int)aowl_hn_submit("f1", "GET", url, NULL, 0, 8000, why, sizeof(why)), why);
        wait_done("f1", 15000);
        report("f1", "f1");
        return 0;
    }
    if (!strcmp(kase, "two_concurrent")) {
        int done = 0, waited = 0;
        char idBuf[AOWL_HN_ID_CAP];
        aowl_hn_configure(1, 4, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/slow", port);
        printf("OUT submit1=%d\n",
               (int)aowl_hn_submit("g1", "GET", url, NULL, 0, 8000, why, sizeof(why)));
        printf("OUT submit2=%d\n",
               (int)aowl_hn_submit("g2", "GET", url, NULL, 0, 8000, why, sizeof(why)));
        while (done < 2 && waited < 20000) {
            if (aowl_hn_take_done(idBuf, sizeof(idBuf))) {
                printf("OUT drained=%s\n", idBuf);
                done++;
            } else { Sleep(20); waited += 20; }
        }
        report("g1", "g1");
        report("g2", "g2");
        return 0;
    }
    if (!strcmp(kase, "inflight_cap")) {
        aowl_hn_configure(1, 1, 1048576);
        aowl_hn_allow_reset();
        aowl_hn_allow_add("127.0.0.1");
        sprintf(url, "http://127.0.0.1:%d/slow", port);
        printf("OUT submit1=%d why=%s\n",
               (int)aowl_hn_submit("h1", "GET", url, NULL, 0, 8000, why, sizeof(why)), why);
        printf("OUT submit2=%d why=%s\n",
               (int)aowl_hn_submit("h2", "GET", url, NULL, 0, 8000, why, sizeof(why)), why);
        wait_done("h1", 15000);
        return 0;
    }
    if (!strcmp(kase, "unknown_id")) {
        aowl_hn_configure(1, 4, 1048576);
        report("z1", "never-submitted");
        return 0;
    }
    if (!strcmp(kase, "playwav")) {
        const char* path = argc > 3 ? argv[3] : "";
        char buf[1024];
        printf("OUT expand=%d value=%s\n",
               (int)aowl_pw_expand("%TEMP%", buf, (int32_t)sizeof(buf)), buf);
        printf("OUT missing=%d why=%s\n",
               (int)aowl_pw_play_path("Z:\\definitely\\not\\here.wav", why, sizeof(why)), why);
        if (path[0])
            printf("OUT real=%d why=%s\n",
                   (int)aowl_pw_play_path(path, why, sizeof(why)), why);
        return 0;
    }
    printf("OUT unknown-case\n");
    return 2;
}
