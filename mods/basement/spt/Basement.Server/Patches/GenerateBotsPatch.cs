using System.Reflection;
using HarmonyLib;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Reflection.Patching;
using SPTarkov.Server.Core.Controllers;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Eft.Bot;
using SPTarkov.Server.Core.Services.Profile;

namespace Basement.Server.Patches;

/// <summary>Prefix on BotController.Generate(MongoId, GenerateBotsRequestData) -- the handler
/// behind POST /client/game/bot/generate (measured: BotStaticRouter ctor registers the URL,
/// BotCallbacks.GenerateBots calls BotController.Generate). One sidecar call per request:
/// POST /aowlspt/basement/spt/bots {map, raidId, wave, requested:[{role,limit,difficulty}]}.
/// The answer's `limits` rewrites Conditions in place (counts, difficulty) for roles the
/// client asked for; `groups` fills PlanStore for the per-bot patches.</summary>
[Injectable]
public sealed class GenerateBotsPatch : AbstractPatch
{
    private static Sidecar? _sidecar;
    private static ISptLogger<GenerateBotsPatch>? _log;
    private static ProfileActivityService? _activity;

    public GenerateBotsPatch(Sidecar sidecar, ISptLogger<GenerateBotsPatch> log, ProfileActivityService activity) : base("Basement.GenerateBots")
    {
        _sidecar = sidecar; _log = log; _activity = activity;
    }

    protected override MethodBase GetTargetMethod() => AccessTools.Method(typeof(BotController), nameof(BotController.Generate));

    [PatchPrefix]
    public static bool Prefix(MongoId sessionId, GenerateBotsRequestData request)
    {
        try { Run(sessionId, request); }
        catch (Exception ex) { _log?.Error("[Basement.Server] GenerateBots prefix threw -- SPT proceeds unchanged: " + ex, null); }
        return true; // never skip SPT's own generation
    }

    private static void Run(MongoId sessionId, GenerateBotsRequestData request)
    {
        var s = _sidecar; if (s == null || !s.Cfg.Enabled) return;
        var session = sessionId.ToString();
        string map = "";
        try { map = _activity?.GetProfileActivityRaidData(sessionId)?.RaidConfiguration?.Location ?? ""; }
        catch (Exception ex) { _log?.Warning("[Basement.Server] no raid configuration for session " + session + " (" + ex.Message + "); map sent empty.", null); }

        var req = new BotsRequest { Map = map, RaidId = session, Wave = PlanStore.NextWave(session) };
        foreach (var c in request.Conditions ?? new List<GenerateCondition>())
            req.Requested.Add(new RequestedRole { Role = c.Role ?? "", Limit = c.Limit, Difficulty = c.Difficulty ?? "" });

        var resp = s.Parse<BotsResponse>(s.Post("/spt/bots", req), "POST /spt/bots");
        if (resp == null) return;
        if (!resp.Ok) { _log?.Info("[Basement.Server] backend declined wave " + req.Wave + " on " + map + ": " + (resp.Note ?? "no note"), null); return; }

        var rewritten = 0;
        if (s.Cfg.RewriteCounts && resp.Limits != null && request.Conditions != null)
        {
            foreach (var l in resp.Limits)
            {
                var c = request.Conditions.FirstOrDefault(x => string.Equals(x.Role, l.Role, StringComparison.OrdinalIgnoreCase));
                if (c == null)
                {
                    _log?.Warning("[Basement.Server] backend asked for role `" + l.Role + "` which the client did not request -- REFUSED (the client only accepts profiles of the role it asked for; use waves for new roles).", null);
                    continue;
                }
                if (l.Limit >= 0 && l.Limit != c.Limit) { c.Limit = l.Limit; rewritten++; }
                if (!string.IsNullOrEmpty(l.Difficulty) && l.Difficulty != c.Difficulty) { c.Difficulty = l.Difficulty; rewritten++; }
            }
        }

        var planned = 0;
        if (resp.Groups != null && resp.Groups.Count > 0)
        {
            PlanStore.Fill(session, resp.Groups);
            planned = resp.Groups.Sum(g => Math.Max(g.Count, g.Names.Count));
        }
        _log?.Info("[Basement.Server] bot/generate wave " + req.Wave + " on `" + map + "`: requested " +
                   string.Join(",", req.Requested.Select(r => r.Role + "x" + r.Limit)) + "; backend planned " + planned +
                   " bots in " + (resp.Groups?.Count ?? 0) + " groups, rewrote " + rewritten + " condition fields; pending after fill = " + PlanStore.Pending(session) + ".", null);
    }
}
