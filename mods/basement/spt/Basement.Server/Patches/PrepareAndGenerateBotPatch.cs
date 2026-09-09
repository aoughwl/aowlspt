using System.Reflection;
using HarmonyLib;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Reflection.Patching;
using SPTarkov.Server.Core.Generators.Bot;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Eft.Common.Tables;
using SPTarkov.Server.Core.Models.Spt.Bots;

namespace Basement.Server.Patches;

/// <summary>Postfix on BotGenerator.PrepareAndGenerateBot(MongoId, BotGenerationDetails) -> BotBase,
/// the one-bot factory BotController.TryGenerateSingleBot calls (measured). Pops the next
/// planned bot for the requested role and writes its name into Info.Nickname /
/// LowerNickname / MainProfileNickname -- the fields GenerateBot itself sets from
/// BotNameService.GenerateUniqueBotNickname (measured set_ calls). The client binds people
/// to bots by Profile.Info.Nickname (Basement.Client People.MatchByNickname).</summary>
[Injectable]
public sealed class PrepareAndGenerateBotPatch : AbstractPatch
{
    private static Sidecar? _sidecar;
    private static ISptLogger<PrepareAndGenerateBotPatch>? _log;

    public PrepareAndGenerateBotPatch(Sidecar sidecar, ISptLogger<PrepareAndGenerateBotPatch> log) : base("Basement.PrepareAndGenerateBot")
    {
        _sidecar = sidecar; _log = log;
    }

    protected override MethodBase GetTargetMethod() => AccessTools.Method(typeof(BotGenerator), nameof(BotGenerator.PrepareAndGenerateBot));

    [PatchPostfix]
    public static void Postfix(MongoId sessionId, BotGenerationDetails botGenerationDetails, BotBase __result)
    {
        try { Run(sessionId, botGenerationDetails, __result); }
        catch (Exception ex) { _log?.Error("[Basement.Server] PrepareAndGenerateBot postfix threw -- bot left as SPT made it: " + ex, null); }
    }

    private static void Run(MongoId sessionId, BotGenerationDetails details, BotBase bot)
    {
        var s = _sidecar; if (s == null || !s.Cfg.Enabled || !s.Cfg.RewriteNames) return;
        if (bot?.Info == null || details?.Role == null) return;
        var planned = PlanStore.Pop(sessionId.ToString(), details.Role);
        if (planned == null) { PlanStore.Unplanned++; return; }
        if (!string.IsNullOrEmpty(planned.Name))
        {
            bot.Info.Nickname = planned.Name;
            bot.Info.LowerNickname = planned.Name.ToLowerInvariant();
            bot.Info.MainProfileNickname = planned.Name;
            PlanStore.Named++;
        }
        if (s.Cfg.WriteGroupId && !string.IsNullOrEmpty(planned.GroupId)) bot.Info.GroupId = planned.GroupId;
        _log?.Debug("[Basement.Server] bot " + details.Role + " -> `" + planned.Name + "` person=" + (planned.PersonId ?? "-") + " group=" + planned.GroupId, null);
    }
}
