/* jsontest.c -- the overlay's JSON reader, against real manager bodies.
 *
 * The reader in `abi/aowlspt_overlay.h` runs on a worker thread inside
 * `EscapeFromTarkov.exe` and is the only thing between the manager's replies
 * and what a player sees. `overlayhost.exe` exercises it end to end, which is
 * the right test and a slow one: it needs a D3D11 device, a window, a live
 * backend and four seconds of wall clock, and when a field comes out wrong it
 * says so as a missing column in a bitmap.
 *
 * This runs the same functions directly, on bodies captured from the real
 * `mods/manager` over the real `aowlspt-backend`, and checks the tables they
 * fill. No device, no sockets, no timing. It is where a parser bug should be
 * caught, and it is why the bodies below are pasted verbatim rather than
 * hand-written: a test written against what the reader expects proves only that
 * the author was consistent.
 *
 *   gcc -O1 -Wno-unused-function -I../../abi jsontest.c -o jsontest.exe
 *
 * No graphics library on the command line, which is a second, weaker version of
 * what `linkprobe.exe` proves.
 */
#define COBJMACROS
#define CINTERFACE
#include <windows.h>
#include <stdio.h>
#include <string.h>

#include "aowlspt_overlay.h"

int32_t aowlspt_nim_patch_fired(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

/* Added alongside `aowlspt_nim_patch_fired` when `abi/aowlspt_detour.h` grew a
 * return-side dispatcher: the same rule applies -- the thunk pool is emitted
 * unconditionally, so any binary that includes the engine has to satisfy both
 * symbols. The overlay routes through neither; its detours are C functions with
 * the right signature, installed with `aowl_hook_install`. */
int32_t aowlspt_nim_patch_returned(int32_t slot, void* regs) {
    (void)slot; (void)regs;
    return 0;
}

static int failures = 0;
static void ok(const char* m) { printf("ok    %s\n", m); }
static void bad(const char* m) { printf("error %s\n", m); failures++; }

static void eq_str(const char* what, const char* got, const char* want) {
    if (strcmp(got, want) == 0) { ok(what); return; }
    printf("error %s: got \"%s\", wanted \"%s\"\n", what, got, want);
    failures++;
}
static void eq_int(const char* what, int got, int want) {
    if (got == want) { ok(what); return; }
    printf("error %s: got %d, wanted %d\n", what, got, want);
    failures++;
}
/* For the sentences the panel composes: the whole string is a paragraph and
 * pinning it word for word would make every wording change a failing test, but
 * the *fact* in it is exactly what must not go missing. */
static void has(const char* what, const char* hay, const char* needle) {
    if (strstr(hay, needle) != NULL) { ok(what); return; }
    printf("error %s: \"%s\" does not contain \"%s\"\n", what, hay, needle);
    failures++;
}
static void hasnt(const char* what, const char* hay, const char* needle) {
    if (strstr(hay, needle) == NULL) { ok(what); return; }
    printf("error %s: \"%s\" contains \"%s\" and must not\n", what, hay, needle);
    failures++;
}

/* ---- captured bodies ------------------------------------------------
 *
 * Taken off `aowlspt-backend --root <stage> --port 7331` with
 * `mods/manager/bin/manager.dll` loaded and `registry/mods.json` staged, with
 * `Accept-Encoding: identity` so they are the bytes the overlay's WinHTTP
 * worker actually receives. The `\\` in the apply messages are real: they are a
 * Windows path inside a JSON string, and they are the specific thing the old
 * brace-scanning reader could not walk. */

static const char* kPanel =
"{\"ok\":true,\"schema\":\"aowlspt.panel/1\",\"side\":\"server\",\"control\":\"present\","
"\"liveKnown\":true,\"summary\":\"7 of 9 registry mods resolve on the server side\","
"\"mods\":["
"{\"guid\":\"aowl.manager\",\"id\":\"aowl.manager\",\"protected\":true,"
"\"name\":\"Mod Manager\","
"\"version\":\"1.0.0\",\"enabled\":true,\"live\":true,\"restart\":false,"
"\"verdict\":\"loaded\",\"reason\":\"enabled by aowl.list.core\"},"
"{\"guid\":\"aowl.sain\",\"id\":\"aowl.sain\",\"protected\":false,"
"\"name\":\"SAIN\",\"version\":\"0.1.0\","
"\"enabled\":true,\"live\":false,\"restart\":false,\"verdict\":\"loaded\","
"\"reason\":\"enabled by aowl.list.raidnight\"},"
"{\"guid\":\"aowl.fovfix\",\"id\":\"aowl.fovfix\",\"name\":\"FOV Fix\","
"\"version\":\"4.1.0\",\"enabled\":false,\"live\":false,\"restart\":false,"
"\"verdict\":\"wrong-side\",\"reason\":\"declares no server side\"}]}";

/* The same three mods from `/aowlspt/mods/list`, which is where `from` and
 * `explicit` live. */
static const char* kList =
"{\"ok\":true,\"side\":\"server\",\"order\":[\"aowl.manager\",\"aowl.sain\"],\"mods\":["
"{\"id\":\"aowl.manager\",\"name\":\"Mod Manager\",\"verdict\":\"loaded\","
"\"reason\":\"enabled by aowl.list.core\",\"from\":\"aowl.list.core\","
"\"explicit\":false,\"order\":0},"
"{\"id\":\"aowl.sain\",\"name\":\"SAIN\",\"verdict\":\"loaded\","
"\"reason\":\"enabled by override\",\"from\":\"override\",\"explicit\":true,"
"\"order\":4},"
"{\"id\":\"aowl.fovfix\",\"name\":\"FOV Fix\",\"verdict\":\"wrong-side\","
"\"reason\":\"declares no server side\",\"from\":\"\",\"explicit\":false,"
"\"order\":-1}],\"problems\":[]}";

/* `/aowlspt/mods/lists`. Two levels of nesting and an array of objects inside
 * each list -- the shape a brace-pair scan reads as four lists with no
 * entries. */
static const char* kLists =
"{\"ok\":true,\"active\":[\"aowl.list.raidnight\"],\"lists\":["
"{\"id\":\"aowl.list.core\",\"name\":\"Core\",\"author\":\"aowlspt\","
"\"version\":\"1.0.0\",\"description\":\"The mod manager and the game server.\","
"\"inherits\":[],\"entries\":["
"{\"id\":\"aowl.manager\",\"enabled\":true,\"note\":\"never off\"},"
"{\"id\":\"aowl.tarkov\",\"enabled\":true}]},"
"{\"id\":\"aowl.list.raidnight\",\"name\":\"Raid Night\",\"author\":\"savannt\","
"\"version\":\"1.0.0\",\"description\":\"Bots turned up.\","
"\"inherits\":[\"aowl.list.vanillaplus\"],\"entries\":["
"{\"id\":\"aowl.morebots\",\"enabled\":true},"
"{\"id\":\"aowl.sain\",\"enabled\":true},"
"{\"id\":\"aowl.fovfix\",\"enabled\":false,\"note\":\"client-only\"}]}]}";

static const char* kConflicts =
"{\"ok\":false,\"excluded\":["
"{\"id\":\"aowl.icebreaker\",\"name\":\"Icebreaker\",\"verdict\":\"missing-dependency\","
"\"reason\":\"requires aowl.morebots >=2.0.0, and 1.0.0 is what is here\","
"\"from\":\"aowl.list.raidnight\",\"explicit\":false,\"order\":-1}],"
"\"problems\":[\"aowl.list.raidnight names aowl.ghost, which the registry does not have\"]}";

/* A toggle's reply: a nested `row`, a nested `apply`, and messages carrying
 * escaped Windows paths. */
static const char* kToggle =
"{\"ok\":true,\"id\":\"aowl.sain\",\"guid\":\"aowl.sain\",\"action\":\"disable\","
"\"control\":\"present\",\"row\":{\"guid\":\"aowl.sain\",\"id\":\"aowl.sain\","
"\"name\":\"SAIN\",\"version\":\"0.1.0\",\"enabled\":false,\"live\":false,"
"\"restart\":false,\"verdict\":\"disabled\",\"reason\":\"you turned it off\"},"
"\"apply\":{\"ok\":true,\"requested\":2,\"deferred\":1,\"restartRequired\":true,"
"\"control\":\"present\",\"results\":["
"{\"id\":\"aowl.manager\",\"action\":\"load\",\"outcome\":\"applied\","
"\"message\":\"aowl.manager is already loaded\"},"
"{\"id\":\"aowl.morebots\",\"action\":\"load\",\"outcome\":\"requested\","
"\"message\":\"asked the host to load C:\\\\Users\\\\savant\\\\aowlspt\\\\mods/morebots/morebots.dll\"},"
"{\"id\":\"aowl.sain\",\"action\":\"unload\",\"outcome\":\"deferred\","
"\"message\":\"it is not marked hot-reloadable, so it cannot be taken out\"}],"
"\"note\":\"the selection is saved; 1 change(s) cannot take effect until the host restarts\"}}";

/* A change reply: `decision` rather than `row`, and the `inEffect` sentence. */
static const char* kClear =
"{\"ok\":true,\"id\":\"aowl.sain\",\"action\":\"clear\",\"decision\":"
"{\"id\":\"aowl.sain\",\"name\":\"SAIN\",\"verdict\":\"loaded\","
"\"reason\":\"enabled by aowl.list.raidnight\",\"from\":\"aowl.list.raidnight\","
"\"explicit\":false,\"order\":4},\"loaded\":7,\"control\":\"present\","
"\"inEffect\":\"apply it with /aowlspt/mods/apply\",\"problems\":[]}";

/* A refusal. The overlay must show the sentence rather than a blank panel. */
static const char* kError =
"{\"ok\":false,\"error\":\"no mod called aowl.clientprobe in registry/mods.json. "
"This manager can only change mods its registry knows.\"}";

static AowlOvMod* find(const char* guid) {
    for (int32_t i = 0; i < g_ov.modCount; i++)
        if (strcmp(g_ov.mods[i].guid, guid) == 0) return &g_ov.mods[i];
    return NULL;
}


/* A panel body from the same backend, after a client host had polled it with a
 * report. Captured the same way as the ones above -- `realbackend.py` sends one
 * poll through `/aowlspt/mods/client/<ver>?hs=..&sq=..&r=..&more=1` and then
 * reads `/panel` -- so the `client*` keys here are the manager's own bytes and
 * not a shape invented to match the reader.
 *
 * Five rows and only three of them answered about, which is the case that
 * matters: `aowl.perf` is client-only and the rotation has not reached it, so
 * its `live` is null and it carries no client keys at all, and `aowl.manager`
 * is a server mod the game will never speak about. Neither is "not running". */
static const char* kClientPanel =
"{\"ok\":true,\"schema\":\"aowlspt.panel/1\",\"side\":\"server\",\"control"
"\":\"present\",\"liveKnown\":true,\"clientHost\":true,\"clientSession\":\""
"a1b2\",\"clientSeq\":3,\"clientRows\":4,\"clientMore\":true,\"summary\":\""
"2 of 10 registry mods resolve on the server side\",\"mods\":[{\"guid\":\"a"
"owl.manager\",\"id\":\"aowl.manager\",\"protected\":true,\"name\":\"Mod Ma"
"nager\",\"version\":\"1.0.0\",\"enabled\":true,\"live\":true,\"restart\":f"
"alse,\"verdict\":\"loaded\",\"reason\":\"enabled by aowl.list.core\"},{\"g"
"uid\":\"aowl.sain\",\"id\":\"aowl.sain\",\"protected\":false,\"name\":\"SA"
"IN\",\"version\":\"0.1.0\",\"enabled\":false,\"live\":false,\"restart\":tr"
"ue,\"clientLive\":false,\"clientWant\":true,\"clientOutcome\":\"on-restart"
"\",\"clientCode\":\"noteardown\",\"verdict\":\"not-selected\",\"reason\":"
"\"no active list mentions it -- the game's host could not do it live -- th"
"at host cannot take any mod out while it runs; it takes effect when the ga"
"me restarts\"},{\"guid\":\"aowl.fovfix\",\"id\":\"aowl.fovfix\",\"protecte"
"d\":false,\"name\":\"FOV Fix\",\"version\":\"4.1.0\",\"enabled\":false,\"l"
"ive\":false,\"restart\":true,\"clientLive\":false,\"clientWant\":true,\"cl"
"ientOutcome\":\"skipped\",\"clientCode\":\"nofile\",\"verdict\":\"not-sele"
"cted\",\"reason\":\"no active list mentions it -- the client host did not "
"try -- it is not installed on the client side\"},{\"guid\":\"aowl.perf\","
"\"id\":\"aowl.perf\",\"protected\":false,\"name\":\"aowl.perf\",\"version"
"\":\"1.0.0\",\"enabled\":false,\"live\":null,\"restart\":false,\"verdict\""
":\"not-selected\",\"reason\":\"no active list mentions it\"},{\"guid\":\"c"
"om.savannt.sptsway\",\"id\":\"com.savannt.sptsway\",\"protected\":false,\""
"name\":\"SPT-SWAY\",\"version\":\"3.2.0\",\"enabled\":false,\"live\":true,"
"\"restart\":false,\"clientLive\":true,\"clientWant\":true,\"clientOutcome"
"\":\"settled\",\"verdict\":\"not-selected\",\"reason\":\"no active list me"
"ntions it\"}]}";

int main(void) {
    int32_t rowsBefore;
    InitializeCriticalSection(&g_ov.cs);

    /* --- the primitives, on the cases that used to be wrong ---------- */
    {
        const char* s = "{\"a\":{\"id\":\"inner\"},\"id\":\"outer\"}";
        const char* e = s + strlen(s);
        char got[32];
        aowl_ov_jtext(aowl_ov_jmem(s, e, "id"), e, got, sizeof(got));
        eq_str("a member is found at this object's depth, not inside a nested one",
               got, "outer");
    }
    {
        /* A key that only exists inside a nested object must not be found at
         * the outer level. The old reader searched the whole body. */
        const char* s = "{\"a\":{\"secret\":\"x\"}}";
        const char* e = s + strlen(s);
        if (aowl_ov_jmem(s, e, "secret") == NULL)
            ok("a key that is only nested is not found at the top level");
        else
            bad("a nested key leaked into the outer object's members");
    }
    {
        const char* s = "{\"m\":\"a\\\\b\\\"c\\nd\"}";
        const char* e = s + strlen(s);
        char got[32];
        aowl_ov_jtext(aowl_ov_jmem(s, e, "m"), e, got, sizeof(got));
        eq_str("escapes are undone", got, "a\\b\"c\nd");
    }
    {
        /* A quote inside a string must not end the object. This is the exact
         * shape of an apply message with a Windows path in it. */
        const char* s = "{\"m\":\"c:\\\\x\\\"}\\\"y\",\"after\":\"seen\"}";
        const char* e = s + strlen(s);
        char got[32];
        aowl_ov_jtext(aowl_ov_jmem(s, e, "after"), e, got, sizeof(got));
        eq_str("a brace inside a string does not end the object", got, "seen");
    }
    {
        const char* s = "{\"n\":null,\"t\":true,\"i\":-42}";
        const char* e = s + strlen(s);
        eq_int("null is null", aowl_ov_jisnull(aowl_ov_jmem(s, e, "n"), e), 1);
        eq_int("true is not null", aowl_ov_jisnull(aowl_ov_jmem(s, e, "t"), e), 0);
        eq_int("a negative int reads", aowl_ov_jint(aowl_ov_jmem(s, e, "i"), e, 0), -42);
    }
    {
        /* Whole-token matching, so one list id being a prefix of another does
         * not light up the wrong row. */
        eq_int("a prefix is not a token",
               aowl_ov_intoken("aowl.list.core.extra", "aowl.list.core"), 0);
        eq_int("a token in a joined list is found",
               aowl_ov_intoken("aowl.list.a, aowl.list.core", "aowl.list.core"), 1);
    }

    /* --- /panel ------------------------------------------------------ */
    aowl_ov_read_panel(kPanel, (int32_t)strlen(kPanel));
    eq_int("panel: three rows", g_ov.modCount, 3);
    eq_str("panel: control", g_ov.control, "present");
    eq_str("panel: side", g_ov.side, "server");
    eq_str("panel: summary", g_ov.summary,
           "7 of 9 registry mods resolve on the server side");
    {
        AowlOvMod* m = find("aowl.fovfix");
        if (!m) { bad("panel: aowl.fovfix missing"); return 1; }
        eq_str("panel: name", m->name, "FOV Fix");
        eq_str("panel: version", m->version, "4.1.0");
        eq_str("panel: verdict", m->verdict, "wrong-side");
        eq_str("panel: reason", m->reason, "declares no server side");
        eq_int("panel: enabled", m->enabled, 0);
        eq_int("panel: live known", m->liveKnown, 1);
        eq_int("panel: not running", m->loaded, 0);
    }
    /* `protected` is the manager's answer about whether it will let a mod be
     * switched off, and it replaced a hardcoded `"aowl.manager"` in the
     * header. A row that loses it silently is a row that grows a button which
     * ends the session it is drawn in. */
    eq_int("panel: the manager's row is protected", find("aowl.manager")->protectedRow, 1);
    eq_int("panel: an ordinary row is not", find("aowl.sain")->protectedRow, 0);
    {
        /* An older manager that does not send the field must not silently
         * unprotect a row that a previous poll marked. */
        const char* older =
            "{\"ok\":true,\"mods\":[{\"guid\":\"aowl.manager\",\"enabled\":true}]}";
        aowl_ov_read_panel(older, (int32_t)strlen(older));
        eq_int("panel: a reply with no `protected` leaves the flag alone",
               find("aowl.manager")->protectedRow, 1);
    }

    /* --- the client host's half --------------------------------------
     *
     * Every check here is one half of the same rule: a row the game's host has
     * answered about carries a fact, and a row it has not answered about
     * carries *nothing*, which is not the same as `false`. The manager enforces
     * it by leaving the keys out; this is the reader agreeing. */
    aowl_ov_read_panel(kClientPanel, (int32_t)strlen(kClientPanel));
    eq_int("client: the wrapper says a client host has reported", g_ov.clientHost, 1);
    eq_str("client: which process it is about", g_ov.clientSession, "a1b2");
    eq_int("client: its sequence number", g_ov.clientSeq, 3);
    eq_int("client: how many rows it has sent", g_ov.clientRows, 4);
    eq_int("client: and that there are more coming", g_ov.clientMore, 1);
    {
        AowlOvMod* m = find("aowl.fovfix");
        eq_int("client: a row it answered about is marked known", m->clientKnown, 1);
        eq_int("client: and says it is not running", m->clientLive, 0);
        eq_int("client: while the client resolution wanted it on", m->clientWant, 1);
        eq_str("client: the outcome word", m->clientOutcome, "skipped");
        eq_str("client: the slug, kept verbatim so it can be quoted",
               m->clientCode, "nofile");
    }
    {
        AowlOvMod* m = find("com.savannt.sptsway");
        eq_int("client: a mod the game says is running is known", m->clientKnown, 1);
        eq_int("client: and running", m->clientLive, 1);
        eq_int("client: so the row is not greyed", m->loaded, 1);
        eq_str("client: a settled row carries no slug", m->clientCode, "");
    }
    {
        /* The whole point. `aowl.perf` is client-only, the rotation has not
         * reached it, and `live` is null -- so nothing may be concluded. A
         * reader that defaulted `clientKnown` to 1 here would draw a mod
         * nobody has asked about as "the client says it is off". */
        AowlOvMod* m = find("aowl.perf");
        eq_int("client: a row with no keys is not known", m->clientKnown, 0);
        eq_int("client: and `live` stayed null, so nothing knows", m->liveKnown, 0);
        eq_int("client: a server-side row is not known either",
               find("aowl.manager")->clientKnown, 0);
    }

    /* --- `live` against a row this process pushed in ------------------
     *
     * `aowl_ov_set_mod` is the client host talking about its own library table.
     * The manager's `live` may not lower it -- unless the manager's answer
     * carries `clientLive`, which means the same host answered again, later,
     * through the backend. Both directions are checked because getting either
     * one wrong is a panel that lies: one greys out every client mod, the other
     * shows an unloaded mod as running for the rest of the session. */
    {
        const char* quiet =
            "{\"ok\":true,\"mods\":[{\"guid\":\"aowl.pushed\",\"enabled\":true,"
            "\"live\":false}]}";
        const char* said =
            "{\"ok\":true,\"mods\":[{\"guid\":\"aowl.pushed\",\"enabled\":true,"
            "\"live\":false,\"clientLive\":false,\"clientWant\":true,"
            "\"clientOutcome\":\"refused\",\"clientCode\":\"unloadfailed\"}]}";
        const char* back =
            "{\"ok\":true,\"mods\":[{\"guid\":\"aowl.pushed\",\"enabled\":true,"
            "\"live\":true,\"clientLive\":true,\"clientWant\":true,"
            "\"clientOutcome\":\"settled\"}]}";
        AowlOvMod* m;
        aowl_ov_set_mod("aowl.pushed", "Pushed", "1.0.0", 1);
        m = find("aowl.pushed");
        eq_int("push: the host's own row is loaded", m->loaded, 1);
        eq_int("push: and marked as the host's", m->hostPushed, 1);

        aowl_ov_read_panel(quiet, (int32_t)strlen(quiet));
        eq_int("push: a backend with no client record cannot lower it",
               find("aowl.pushed")->loaded, 1);

        aowl_ov_read_panel(said, (int32_t)strlen(said));
        eq_int("push: a backend carrying the client host's own answer can",
               find("aowl.pushed")->loaded, 0);
        eq_str("push: and the slug came with it",
               find("aowl.pushed")->clientCode, "unloadfailed");

        aowl_ov_read_panel(back, (int32_t)strlen(back));
        eq_int("push: and can raise it again", find("aowl.pushed")->loaded, 1);
        eq_str("push: the slug is cleared, not left over",
               find("aowl.pushed")->clientCode, "");

        /* And the record going away. A new game process, or a guid the registry
         * stopped naming: the keys vanish and the row goes back to unknown
         * rather than keeping an answer about a process that has ended. */
        aowl_ov_read_panel(quiet, (int32_t)strlen(quiet));
        eq_int("push: a reply that stops carrying the keys clears `known`",
               find("aowl.pushed")->clientKnown, 0);
        eq_int("push: and the row keeps what it last knew, not `off`",
               find("aowl.pushed")->loaded, 1);
    }
    {
        /* The bug this all started from: the host pushes a row on *unload* too,
         * and the row used to be pinned loaded. Nothing else in this file
         * exercises it, because no backend is involved -- this is the panel a
         * player sees when the backend is unreachable. */
        AowlOvMod* m;
        aowl_ov_set_mod("aowl.gone", "Removed", "2.0.0", 1);
        eq_int("push: loaded before the unload", find("aowl.gone")->loaded, 1);
        aowl_ov_set_mod("aowl.gone", "Removed", "2.0.0", 0);
        m = find("aowl.gone");
        eq_int("push: a mod the host unloaded does not read as running",
               m->loaded, 0);
        eq_str("push: and says so", m->verdict, "unloaded");
        eq_str("push: with the host's own sentence", m->reason,
               "taken out of this process; the client host said so");
    }

    /* --- the sentence the detail pane prints -------------------------
     *
     * Four states, and the last three are all "unknown". They have to read
     * differently: a rotation that has not got here yet, a complete report that
     * did not mention this mod, and no client host at all are three different
     * things to do about it, and a panel that renders one word for all three
     * makes the player guess which. */
    {
        char line[320];
        uint32_t col = 0;
        AowlOvMod* m = find("aowl.fovfix");
        aowl_ov_client_line(m, line, (int32_t)sizeof(line), &col);
        has("line: a reported row says what the game is doing", line,
            "in the game: not running");
        has("line: and what was asked of it", line, "wanted it on");
        has("line: the outcome word", line, "skipped");
        has("line: the slug, so it can be quoted in a bug report", line, "[nofile]");
        has("line: and the sentence behind the slug", line,
            "it is not installed on the client side");
        eq_int("line: a disagreement is coloured as one", (int)col, (int)AOWL_OV_WARN);
        eq_str("line: `running` on that row is a no with a source",
               aowl_ov_run_word(m), "no");

        m = find("aowl.perf");
        g_ov.sClientHost = 1; g_ov.sClientMore = 1; g_ov.sClientRows = 4;
        aowl_ov_client_line(m, line, (int32_t)sizeof(line), &col);
        has("line: an unreached row says it is unknown", line,
            "in the game: unknown");
        has("line: and that the report is still arriving", line, "instalments");
        hasnt("line: and never that it is off", line, "not running");
        eq_str("line: `running` on it is unknown", aowl_ov_run_word(m), "unknown");

        g_ov.sClientMore = 0;
        aowl_ov_client_line(m, line, (int32_t)sizeof(line), &col);
        has("line: a complete report that missed it says that instead", line,
            "none of them was this mod");
        hasnt("line: still not off", line, "not running");

        g_ov.sClientHost = 0; g_ov.sClientRows = 0;
        aowl_ov_client_line(m, line, (int32_t)sizeof(line), &col);
        /* And the wording of this one is checked, not just its existence. The
         * panel is drawn inside the game, so "no game is running" is never the
         * explanation for `clientHost:false` -- the host in this very process
         * has not reported, and a sentence that sent a player off to check
         * whether their game was up would be sending them nowhere. */
        has("line: with no report at all, it says which process is silent", line,
            "the client host in this process has not reported");
        has("line: out loud, so nobody reads it as a negative", line,
            "Not the same as `not running`");
    }

    /* --- /list, merged onto the same rows ---------------------------- */
    /* Against whatever the panel sections above left in the table rather than a
     * literal: `/list` names the same three mods, and the property being
     * checked is that reading it adds none of its own. */
    rowsBefore = g_ov.modCount;
    aowl_ov_read_list(kList, (int32_t)strlen(kList));
    eq_int("list: no new rows appeared", g_ov.modCount, rowsBefore);
    {
        AowlOvMod* m = find("aowl.sain");
        eq_str("list: from", m->from, "override");
        eq_int("list: explicit", m->explicitOv, 1);
        eq_int("list: order", m->order, 4);
        /* The version came from /panel and must survive a route that has none. */
        eq_str("list: version survived the merge", m->version, "0.1.0");
    }
    {
        AowlOvMod* m = find("aowl.fovfix");
        eq_str("list: an empty `from` replaces, rather than being ignored",
               m->from, "");
        eq_int("list: not explicit", m->explicitOv, 0);
    }

    /* --- /lists ------------------------------------------------------ */
    aowl_ov_read_lists(kLists, (int32_t)strlen(kLists));
    eq_int("lists: two lists", g_ov.listCount, 2);
    eq_str("lists: active", g_ov.activeLists, "aowl.list.raidnight");
    eq_int("lists: core is not active", g_ov.lists[0].active, 0);
    eq_int("lists: raidnight is active", g_ov.lists[1].active, 1);
    eq_str("lists: name", g_ov.lists[1].name, "Raid Night");
    eq_str("lists: inherits", g_ov.lists[1].inherits, "aowl.list.vanillaplus");
    eq_int("lists: five entries across both", g_ov.entryCount, 5);
    eq_int("lists: core has two", g_ov.lists[0].entries, 2);
    eq_int("lists: raidnight has three", g_ov.lists[1].entries, 3);
    {
        int32_t found = 0;
        for (int32_t i = 0; i < g_ov.entryCount; i++)
            if (strcmp(g_ov.entries[i].id, "aowl.fovfix") == 0) {
                found = 1;
                eq_int("lists: a disabled entry is disabled", g_ov.entries[i].enabled, 0);
                eq_str("lists: the entry's note", g_ov.entries[i].note, "client-only");
                eq_int("lists: the entry belongs to the right list",
                       g_ov.entries[i].list, 1);
            }
        if (!found) bad("lists: the nested entries array was not walked");
    }
    /* Read twice: the tables are rebuilt, not appended to. A poll every three
     * seconds that doubled the list count would overflow in a minute. */
    aowl_ov_read_lists(kLists, (int32_t)strlen(kLists));
    eq_int("lists: a second read replaces rather than appends", g_ov.listCount, 2);
    eq_int("lists: entries too", g_ov.entryCount, 5);

    /* --- /conflicts -------------------------------------------------- */
    aowl_ov_read_conflicts(kConflicts, (int32_t)strlen(kConflicts));
    eq_int("conflicts: one exclusion and one problem", g_ov.issueCount, 2);
    eq_str("conflicts: the excluded mod", g_ov.issues[0].id, "aowl.icebreaker");
    eq_str("conflicts: its verdict", g_ov.issues[0].verdict, "missing-dependency");
    eq_str("conflicts: its reason", g_ov.issues[0].text,
           "requires aowl.morebots >=2.0.0, and 1.0.0 is what is here");
    eq_str("conflicts: the registry problem", g_ov.issues[1].verdict, "registry");

    /* --- a toggle reply ---------------------------------------------- */
    aowl_ov_read_reply(kToggle, (int32_t)strlen(kToggle), "disable aowl.sain");
    {
        AowlOvMod* m = find("aowl.sain");
        eq_int("toggle: the row came back disabled", m->enabled, 0);
        eq_str("toggle: the row's verdict", m->verdict, "disabled");
        eq_str("toggle: the row's reason", m->reason, "you turned it off");
        eq_int("toggle: pending cleared", m->pending, 0);
    }
    eq_int("toggle: requested", g_ov.applyRequested, 2);
    eq_int("toggle: deferred", g_ov.applyDeferred, 1);
    eq_int("toggle: restartRequired", g_ov.applyRestart, 1);
    eq_str("toggle: apply control", g_ov.applyControl, "present");
    eq_int("toggle: three per-mod outcomes", g_ov.resultCount, 3);
    eq_str("toggle: the first outcome", g_ov.results[0].outcome, "applied");
    eq_str("toggle: the deferred one", g_ov.results[2].outcome, "deferred");
    eq_str("toggle: its action", g_ov.results[2].action, "unload");
    eq_str("toggle: the host's own message", g_ov.results[2].message,
           "it is not marked hot-reloadable, so it cannot be taken out");
    /* The one with the Windows path in it: the escaped backslashes must arrive
     * as single backslashes and the row after it must still have been read. */
    eq_str("toggle: an escaped Windows path survives", g_ov.results[1].message,
           "asked the host to load C:\\Users\\savant\\aowlspt\\mods/morebots/morebots.dll");
    eq_str("toggle: the manager's note", g_ov.applyNote,
           "the selection is saved; 1 change(s) cannot take effect until the host restarts");

    /* --- a change reply ---------------------------------------------- */
    aowl_ov_read_reply(kClear, (int32_t)strlen(kClear), "clear aowl.sain");
    {
        AowlOvMod* m = find("aowl.sain");
        eq_str("clear: the decision's verdict", m->verdict, "loaded");
        eq_str("clear: the decision's from", m->from, "aowl.list.raidnight");
        eq_int("clear: the override is gone", m->explicitOv, 0);
    }
    eq_str("clear: the manager's inEffect sentence", g_ov.inEffect,
           "apply it with /aowlspt/mods/apply");

    /* --- a refusal ---------------------------------------------------- */
    aowl_ov_read_reply(kError, (int32_t)strlen(kError), "enable aowl.clientprobe");
    eq_str("error: the manager's own sentence is kept", g_ov.lastError,
           "no mod called aowl.clientprobe in registry/mods.json. This manager "
           "can only change mods its registry knows.");
    eq_int("error: no stale outcomes are left behind", g_ov.resultCount, 0);

    /* --- rubbish ------------------------------------------------------
     *
     * Not a crash and not a wiped table: a body that is not what was asked for
     * is a transport fault, and the panel's job then is to keep showing the
     * last thing it knew. */
    {
        int32_t before = g_ov.modCount;
        const char* junk = "<html><body>502 Bad Gateway</body></html>";
        aowl_ov_read_panel(junk, (int32_t)strlen(junk));
        eq_int("junk: the rows survive a body that is not JSON", g_ov.modCount, before);
        junk = "{\"ok\":true,\"mods\":[{\"guid\":\"unterminated";
        aowl_ov_read_panel(junk, (int32_t)strlen(junk));
        eq_int("junk: an unterminated body adds no row", g_ov.modCount, before);
        /* And the tables that a reader *rebuilds* are not emptied by a bad
         * body either. `aowl_ov_read_lists` clears `listCount` before it
         * refills it, so without the balance check up front a truncated answer
         * would blank the whole LISTS view for one poll and fill it back in on
         * the next -- a panel that flickers empty every time a request is cut
         * short. */
        int32_t lists = g_ov.listCount;
        aowl_ov_read_lists("", 0);
        eq_int("junk: an empty body does not empty the lists", g_ov.listCount, lists);
        aowl_ov_read_lists("{\"lists\":[{\"id\":\"aowl.list.tr",
                           (int32_t)strlen("{\"lists\":[{\"id\":\"aowl.list.tr"));
        eq_int("junk: a truncated body does not empty the lists",
               g_ov.listCount, lists);
    }

    printf("\n%s\n", failures == 0 ? "all overlay json checks passed"
                                   : "some overlay json checks failed");
    return failures == 0 ? 0 : 1;
}
