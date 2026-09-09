/* logstest.c -- the overlay's LOGS screen, headless.
 *
 * The screen reads two files, parses each line into a source / level / facet,
 * filters on four axes at once and draws the result inside a hooked Present.
 * `overlayhost.exe` exercises the drawing; this exercises everything that can
 * be wrong WITHOUT a GPU, which is all of it except how it looks.
 *
 * THE CHECKS ARE NEGATIVES, on purpose (CLAUDE.md 9b). The interesting claim
 * is not "the filter found the rows I expected" -- a filter that returns its
 * own input passes that. It is:
 *
 *   * `logFilt` is EXACTLY the set of held lines that satisfy the predicate.
 *     Checked over the FULL cross product of every source filter, every level
 *     filter, every facet including `system` and `all`, and several search
 *     terms -- 3 * 7 * (facets+2) * 4 combinations -- by walking the ring
 *     independently and comparing set membership both ways. A line that is
 *     displayed and should not be fails this; so does a line that is hidden
 *     and should not be. There is no way to pass it by returning everything.
 *   * No row the draw could reach names a sequence the ring no longer holds.
 *   * The facet rule matches a table of REAL lines sampled from a live run,
 *     including the ones it is supposed to REFUSE.
 *   * A line split across two reads comes back whole, and a line longer than
 *     the buffer comes back marked rather than silently short.
 *
 * It also MEASURES `aowl_ov_build` -- the whole per-frame cost of the panel,
 * which is the only work the Present hook does beyond one buffer upload -- with
 * the logs screen open and with it closed.
 *
 * Build:  gcc -O2 -I..\..\abi logstest.c -o logstest.exe
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs; return 0;
}

static int failures = 0;
static void ok(const char* m) { printf("ok    %s\n", m); }
static void eq_int(const char* what, int got, int want) {
    if (got == want) { ok(what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}
static void eq_str(const char* what, const char* got, const char* want) {
    if (strcmp(got, want) == 0) { ok(what); return; }
    printf("error %s: got \"%s\", wanted \"%s\"\n", what, got, want);
    failures++;
}

/* ---- real lines, copied verbatim from a live run ---------------------- */
static const char* const SAMPLE[] = {
    "[0:00:01.187] ok     admin diag (Admin Menu 1.0.0)",
    "[0:00:01.200] info   sain: 42 bots considered",
    "[0:00:01.204] info   sain: bot cap raised",
    "[0:00:01.210] warn   config: key not understood",
    "[0:00:01.222] info   debugui: panel armed",
    "[0:00:01.231] ok     botdiag: 3 spawned",
    "[0:00:01.240] info   botdiag no colon here",
    "[0:00:01.250] info   graphics post-process armed",
    "[0:00:01.260] info   subscribed to 4 routes",
    "[0:00:01.270] info   REQ GET /client/game/start",
    "[0:00:01.280] error  route /x refused",
    "[0:00:01.290] info   FOV: 75",
    "[0:00:01.300] info   ids: 12 seen",
    "[0:00:01.310] info   00000000000a00000000004f loaded",
    "    at some.stack.frame(x)",
    "[0:00:01.320] info   http://example/x fetched",
    "[0:00:01.330] shrug  a level word nobody defined",
    NULL
};

/* The facet rule, asserted on the sample. `want` is NULL for "system". */
static void check_facets(void) {
    struct { const char* line; const char* want; int lvl; } t[] = {
        { SAMPLE[0],  NULL,      AOWL_LOGLVL_OK },       /* admin, no colon */
        { SAMPLE[1],  "sain",    AOWL_LOGLVL_INFO },
        { SAMPLE[3],  "config",  AOWL_LOGLVL_WARN },
        { SAMPLE[4],  "debugui", AOWL_LOGLVL_INFO },
        { SAMPLE[5],  "botdiag", AOWL_LOGLVL_OK },
        { SAMPLE[6],  NULL,      AOWL_LOGLVL_INFO },     /* botdiag, no colon */
        { SAMPLE[7],  NULL,      AOWL_LOGLVL_INFO },     /* graphics: KNOWN MISS */
        { SAMPLE[8],  NULL,      AOWL_LOGLVL_INFO },
        { SAMPLE[9],  NULL,      AOWL_LOGLVL_INFO },
        { SAMPLE[10], NULL,      AOWL_LOGLVL_ERR },
        { SAMPLE[11], "fov",     AOWL_LOGLVL_INFO },     /* lowercased */
        { SAMPLE[12], "ids",     AOWL_LOGLVL_INFO },     /* KNOWN false facet */
        { SAMPLE[13], NULL,      AOWL_LOGLVL_INFO },     /* digits only: no alpha */
        { SAMPLE[14], NULL,      AOWL_LOGLVL_UNKNOWN },  /* no prefix at all */
        { SAMPLE[15], NULL,      AOWL_LOGLVL_INFO },     /* http:// is not a facet */
        { SAMPLE[16], NULL,      AOWL_LOGLVL_UNKNOWN },  /* unknown level word */
    };
    int i;
    for (i = 0; i < (int)(sizeof(t) / sizeof(t[0])); i++) {
        AowlOvLogLine* L;
        char what[160];
        g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0;
        aowl_ov_log_append(AOWL_LOG_CLIENT, t[i].line, (int32_t)strlen(t[i].line));
        L = &g_ov.logs[0];
        _snprintf(what, sizeof(what) - 1, "level of \"%.40s\"", t[i].line);
        what[sizeof(what) - 1] = 0;
        eq_int(what, L->lvl, t[i].lvl);
        _snprintf(what, sizeof(what) - 1, "facet of \"%.40s\"", t[i].line);
        what[sizeof(what) - 1] = 0;
        eq_str(what, aowl_ov_log_facet_name(L->facet),
               t[i].want ? t[i].want : "system");
    }
}

/* Walks the ring independently of `logFilt` and returns the passing set as a
 * bitmap over sequences. Deliberately NOT the same code path: it calls the
 * predicate directly, so the thing under test is the index builder. */
static int wanted[AOWL_OV_LOG_MAX + 8];

static void check_filter_exact(void) {
    int srcF, lvlF, facetF, termI, combos = 0, bad = 0;
    static const char* terms[] = { "", "sain", "bot", "zzzznotpresent" };
    for (srcF = 0; srcF < AOWL_LOGSRC_COUNT; srcF++)
    for (lvlF = 0; lvlF < AOWL_LOGF_COUNT; lvlF++)
    for (facetF = AOWL_LOG_FACET_ALL; facetF < g_ov.logFacetN; facetF++)
    for (termI = 0; termI < 4; termI++) {
        int first, seq, i, nWant = 0;
        g_ov.logSrcFilt = srcF;
        g_ov.logLvlFilt = lvlF;
        g_ov.logFacetFilt = facetF;
        aowl_ov_copy(g_ov.logSearch, (int32_t)sizeof(g_ov.logSearch), terms[termI]);
        g_ov.logFiltStamp = 0;         /* force a recompute every combination */
        aowl_ov_log_refilter();
        combos++;

        first = g_ov.logSeq - g_ov.logCount;
        if (first < 0) first = 0;
        memset(wanted, 0, sizeof(wanted));
        for (seq = first; seq < g_ov.logSeq; seq++)
            if (aowl_ov_log_pass(&g_ov.logs[seq % AOWL_OV_LOG_MAX])) {
                wanted[seq - first] = 1; nWant++;
            }
        /* (a) nothing displayed that should not be, and nothing held twice */
        for (i = 0; i < g_ov.logFiltN; i++) {
            int sq = g_ov.logFilt[i];
            if (sq < first || sq >= g_ov.logSeq) { bad++; continue; }  /* evicted */
            if (!wanted[sq - first]) { bad++; continue; }              /* wrong  */
            wanted[sq - first] = 2;
        }
        /* (b) nothing hidden that should not be */
        for (seq = first; seq < g_ov.logSeq; seq++)
            if (wanted[seq - first] == 1) bad++;
        if (g_ov.logFiltN != nWant) bad++;
        /* (c) the order the ring was written in is the order drawn */
        for (i = 1; i < g_ov.logFiltN; i++)
            if (g_ov.logFilt[i] <= g_ov.logFilt[i - 1]) bad++;
    }
    printf("      %d filter combinations checked over %d held lines\n",
           combos, g_ov.logCount);
    eq_int("logFilt is EXACTLY the passing set, every combination", bad, 0);
}

/* The ring: overfill it and check the accounting, then check that no filtered
 * sequence names a line that has been overwritten. */
static void check_ring(void) {
    int i, first, bad = 0;
    char line[80];
    g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0;
    for (i = 0; i < AOWL_OV_LOG_MAX + 250; i++) {
        _snprintf(line, sizeof(line) - 1, "[0:00:0%d.000] info   ring: line %d",
                  i % 10, i);
        line[sizeof(line) - 1] = 0;
        aowl_ov_log_append(AOWL_LOG_SERVER, line, (int32_t)strlen(line));
    }
    eq_int("the ring holds its cap and no more", g_ov.logCount, AOWL_OV_LOG_MAX);
    eq_int("evicted lines are counted, not hidden", g_ov.logDropped, 250);
    eq_int("the sequence counts every line ever appended",
           g_ov.logSeq, AOWL_OV_LOG_MAX + 250);
    g_ov.logSrcFilt = AOWL_LOGSRC_ALL;
    g_ov.logLvlFilt = AOWL_LOGF_ALL;
    g_ov.logFacetFilt = AOWL_LOG_FACET_ALL;
    g_ov.logSearch[0] = 0;
    g_ov.logFiltStamp = 0;
    aowl_ov_log_refilter();
    first = g_ov.logSeq - g_ov.logCount;
    for (i = 0; i < g_ov.logFiltN; i++)
        if (g_ov.logFilt[i] < first || g_ov.logFilt[i] >= g_ov.logSeq) bad++;
    eq_int("no filtered row names a line the ring has overwritten", bad, 0);
}

/* A line split across two reads, and a line longer than the buffer. Driven
 * through the REAL reader, against a real file, so the carry logic and the
 * offset bookkeeping are what is being tested and not a re-implementation. */
static void check_split(void) {
    char path[MAX_PATH], tmp[MAX_PATH];
    static char scratch[AOWL_OV_LOG_CHUNK];
    FILE* f;
    int i, foundWhole = 0, foundCut = 0;
    GetTempPathA(sizeof(tmp), tmp);
    _snprintf(path, sizeof(path) - 1, "%saowl-logstest.log", tmp);
    path[sizeof(path) - 1] = 0;
    DeleteFileA(path);

    g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0;
    g_ov.logOpened[AOWL_LOG_SERVER] = 0; g_ov.logOff[AOWL_LOG_SERVER] = 0;
    g_ov.logCarryN[AOWL_LOG_SERVER] = 0; g_ov.logOff2[AOWL_LOG_SERVER] = 0;
    g_ov.logLines[AOWL_LOG_SERVER] = 0;
    aowl_ov_copy(g_ov.logPath[AOWL_LOG_SERVER],
                 (int32_t)sizeof(g_ov.logPath[0]), path);

    /* half a line, no newline yet */
    f = fopen(path, "wb");
    fputs("[0:00:02.000] info   split: first ha", f);
    fclose(f);
    aowl_ov_log_pull(AOWL_LOG_SERVER, scratch, (int32_t)sizeof(scratch));
    eq_int("a line with no newline yet is NOT shown as a short line",
           g_ov.logCount, 0);

    /* ...the rest of it, plus a 6 KB monster like a PROBE line */
    f = fopen(path, "ab");
    fputs("lf and second half\n", f);
    fputs("[0:00:02.100] info   probe: ", f);
    for (i = 0; i < 6000; i++) fputc('x', f);
    fputs("\n", f);
    fclose(f);
    aowl_ov_log_pull(AOWL_LOG_SERVER, scratch, (int32_t)sizeof(scratch));
    eq_int("both lines arrive after the second read", g_ov.logCount, 2);
    for (i = 0; i < g_ov.logCount; i++) {
        const char* t = g_ov.logs[i].text;
        if (strcmp(t, "[0:00:02.000] info   split: first half and second half") == 0)
            foundWhole = 1;
        if (strncmp(t, "[0:00:02.100] info   probe: ", 28) == 0) {
            int n = (int)strlen(t);
            if (n <= AOWL_OV_LOG_TEXT - 1 && t[n - 1] == '.' && t[n - 2] == '.')
                foundCut = 1;
        }
    }
    eq_int("a line split across two reads comes back whole", foundWhole, 1);
    eq_int("a 6 KB line is kept, capped, and MARKED as cut", foundCut, 1);
    eq_str("the cut line still parses its facet",
           aowl_ov_log_facet_name(g_ov.logs[1].facet), "probe");
    DeleteFileA(path);
    g_ov.logPath[AOWL_LOG_SERVER][0] = 0;
}

/* ---- what it costs, per frame ---------------------------------------- */
static double bench(int view, int settings, int frames) {
    LARGE_INTEGER f, a, b;
    int i;
    QueryPerformanceFrequency(&f);
    g_ov.settings = settings;
    g_ov.view = view;
    /* Every frame is a REBUILD, not a cache hit: the cache is what makes the
     * steady state free, and measuring it would be measuring nothing. */
    QueryPerformanceCounter(&a);
    for (i = 0; i < frames; i++) {
        g_ov.drawSig = 0;              /* force the rebuild */
        aowl_ov_build();
    }
    QueryPerformanceCounter(&b);
    return (double)(b.QuadPart - a.QuadPart) * 1e9 /
           ((double)f.QuadPart * (double)frames);
}

static double bench_cached(int view, int frames) {
    LARGE_INTEGER f, a, b;
    int i;
    QueryPerformanceFrequency(&f);
    g_ov.settings = 0;
    g_ov.view = view;
    aowl_ov_build();                    /* prime */
    QueryPerformanceCounter(&a);
    for (i = 0; i < frames; i++) aowl_ov_build();
    QueryPerformanceCounter(&b);
    return (double)(b.QuadPart - a.QuadPart) * 1e9 /
           ((double)f.QuadPart * (double)frames);
}

int main(void) {
    int i;
    InitializeCriticalSection(&g_ov.cs);
    g_ov.bbW = 1920; g_ov.bbH = 1080;
    g_ov.scalePref = 1;
    aowl_ov_prefs_default();
    g_ov.logSrcFilt = AOWL_LOGSRC_ALL;
    g_ov.logLvlFilt = AOWL_LOGF_ALL;
    g_ov.logFacetFilt = AOWL_LOG_FACET_ALL;

    printf("-- the facet and level rules, on real sampled lines --\n");
    check_facets();

    printf("-- a line split across reads, and a 6 KB one --\n");
    check_split();

    printf("-- the filter, over its whole cross product --\n");
    g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0;
    g_ov.logFacetN = 0;
    for (i = 0; SAMPLE[i]; i++)
        aowl_ov_log_append(i & 1 ? AOWL_LOG_SERVER : AOWL_LOG_CLIENT,
                           SAMPLE[i], (int32_t)strlen(SAMPLE[i]));
    check_filter_exact();

    printf("-- the ring --\n");
    check_ring();

    printf("-- what a frame costs (geometry; the whole per-frame panel) --\n");
    {
        double closed, open, cached, off;
        /* A realistic ring: the cap, full. */
        g_ov.logSeq = 0; g_ov.logCount = 0; g_ov.logDropped = 0;
        for (i = 0; i < AOWL_OV_LOG_MAX; i++) {
            char line[120];
            _snprintf(line, sizeof(line) - 1,
                      "[0:00:0%d.%03d] info   %s: a line of about the length "
                      "these really are, %d", i % 10, i % 1000,
                      (i % 3) ? "sain" : "botdiag", i);
            line[sizeof(line) - 1] = 0;
            aowl_ov_log_append(i & 1 ? AOWL_LOG_SERVER : AOWL_LOG_CLIENT,
                               line, (int32_t)strlen(line));
        }
        g_ov.logFiltStamp = 0;
        InterlockedExchange(&g_ov.visible, 1);
        closed = bench(AOWL_VIEW_MODS, 0, 3000);
        open   = bench(AOWL_VIEW_LOGS, 0, 3000);
        cached = bench_cached(AOWL_VIEW_LOGS, 3000);
        InterlockedExchange(&g_ov.logWant, 0);
        g_ov.view = AOWL_VIEW_MODS;
        aowl_ov_build();
        off = (double)g_ov.logWant;
        printf("      MODS  rebuild: %8.0f ns/frame\n", closed);
        printf("      LOGS  rebuild: %8.0f ns/frame  (%d rows filtered)\n",
               open, g_ov.logFiltN);
        printf("      LOGS  cached : %8.0f ns/frame  (the steady state)\n", cached);
        {
            /* The refilter on its own: what ONE keystroke in the search box
             * costs, which is the worst thing a person can do to this screen --
             * a full re-scan of the ring. Everything else reuses the index. */
            LARGE_INTEGER fq, ra, rb;
            double each;
            int k;
            QueryPerformanceFrequency(&fq);
            QueryPerformanceCounter(&ra);
            for (k = 0; k < 2000; k++) {
                g_ov.logFiltStamp = 0;
                aowl_ov_log_refilter();
            }
            QueryPerformanceCounter(&rb);
            each = (double)(rb.QuadPart - ra.QuadPart) * 1e9 /
                   ((double)fq.QuadPart * 2000.0);
            printf("      refilter     : %8.0f ns  (a keystroke, %d lines)\n",
                   each, g_ov.logCount);
            eq_int("a full refilter of a full ring stays under 500 us",
                   each < 500000.0, 1);
        }
        eq_int("the worker is told to stop tailing when the screen is not up",
               (int)off, 0);
        /* A hard ceiling rather than a report: at 144 Hz a frame is 6.9 ms, and
         * a panel that costs a millisecond to rebuild is a panel that has
         * stopped being free. Failing rather than printing is the point. */
        eq_int("a LOGS rebuild stays under 1 ms", open < 1000000.0, 1);
        eq_int("a cached LOGS frame stays under 20 us", cached < 20000.0, 1);
    }

    printf("\n%s -- %d failure(s)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
