using System.Reflection;
using HarmonyLib;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Reflection.Patching;
using SPTarkov.Server.Core.Generators.Bot;
using SPTarkov.Server.Core.Helpers.Bot;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Eft.Common.Tables;
using SPTarkov.Server.Core.Models.Spt.Bots;
using SPTarkov.Server.Core.Utils.Cloners;

namespace Basement.Server.Patches;

/// <summary>Prefix on BotInventoryGenerator.GenerateInventory(MongoId botId, MongoId sessionId,
/// BotType botJsonTemplate, BotGenerationDetails) -- called exactly once per bot from
/// BotGenerator.GenerateBot (measured: the only call site). When the planned bot names a
/// `loadout` role, the TEMPLATE argument is swapped for a clone of that role's bot-db
/// template (BotHelper.GetBotTemplate(role), measured), so SPT's own weapon/equipment/loot
/// generators build the kit. No item tree is ever hand-built here.</summary>
[Injectable]
public sealed class GenerateInventoryPatch : AbstractPatch
{
    private static Sidecar? _sidecar;
    private static ISptLogger<GenerateInventoryPatch>? _log;
    private static BotHelper? _botHelper;
    private static ICloner? _cloner;

    public GenerateInventoryPatch(Sidecar sidecar, ISptLogger<GenerateInventoryPatch> log, BotHelper botHelper, ICloner cloner) : base("Basement.GenerateInventory")
    {
        _sidecar = sidecar; _log = log; _botHelper = botHelper; _cloner = cloner;
    }

    protected override MethodBase GetTargetMethod() => AccessTools.Method(typeof(BotInventoryGenerator), nameof(BotInventoryGenerator.GenerateInventory));

    [PatchPrefix]
    public static bool Prefix(MongoId sessionId, ref BotType botJsonTemplate, BotGenerationDetails botGenerationDetails)
    {
        try { Run(sessionId, ref botJsonTemplate, botGenerationDetails); }
        catch (Exception ex) { _log?.Error("[Basement.Server] GenerateInventory prefix threw -- SPT template kept: " + ex, null); }
        return true;
    }

    private static void Run(MongoId sessionId, ref BotType template, BotGenerationDetails details)
    {
        var s = _sidecar; if (s == null || !s.Cfg.Enabled || !s.Cfg.RewriteLoadouts) return;
        if (details?.Role == null) return;
        var planned = PlanStore.Peek(sessionId.ToString(), details.Role);
        if (planned == null || string.IsNullOrEmpty(planned.Loadout)) return;
        if (string.Equals(planned.Loadout, details.Role, StringComparison.OrdinalIgnoreCase)) return;
        BotType? donor;
        try { donor = _botHelper?.GetBotTemplate(planned.Loadout); }
        catch (Exception ex) { _log?.Warning("[Basement.Server] loadout `" + planned.Loadout + "` is not a bot-db role (" + ex.Message + ") -- SPT template kept.", null); return; }
        if (donor?.BotInventory == null) { _log?.Warning("[Basement.Server] loadout `" + planned.Loadout + "` has no inventory template -- SPT template kept.", null); return; }
        var clone = _cloner != null ? _cloner.Clone(donor) : donor;
        if (clone == null) return;
        template = clone;
        PlanStore.LoadoutSwapped++;
        _log?.Debug("[Basement.Server] inventory for " + details.Role + " `" + planned.Name + "` generated from `" + planned.Loadout + "` template.", null);
    }
}
