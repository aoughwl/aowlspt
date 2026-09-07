using System.Reflection;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Reflection.Patching;
using SPTarkov.Server.Core.DI;
using SPTarkov.Server.Core.Helpers.Server;

namespace Basement.Server;

/// <summary>Mod entry. SPT 4.1.5 constructs every [Injectable] class through its DI container and
/// calls IOnLoad.OnLoadAsync in TypePriority order (OnLoadOrder.PostLoad = 1000000; the
/// MoreBots server mod runs at PostLoad+5, measured). Server methods are NOT virtual on
/// 4.1.5 (measured: none of BotController / BotGenerator / BotInventoryGenerator /
/// LocationLifecycleService), so the only override mechanism is a Harmony patch through
/// SPTarkov.Reflection.Patching.AbstractPatch -- the pattern acidphantasm-botplacementsystem
/// uses on this very install. Only THIS assembly's patches are enabled here.</summary>
[Injectable(InjectionType = InjectionType.Singleton, TypePriority = OnLoadOrder.PostLoad + 7)]
public sealed class BasementServer(ISptLogger<BasementServer> logger, ModHelper modHelper, Sidecar sidecar, IEnumerable<IRuntimePatch> patches) : IOnLoad
{
    public Task OnLoadAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var cfg = Config.Load(modHelper, out var source);
        sidecar.Cfg = cfg;
        if (!cfg.Enabled)
        {
            logger.Warning("[Basement.Server] disabled by " + source + " -- no patch enabled, SPT generates bots and waves itself.", null);
            return Task.CompletedTask;
        }
        var mine = typeof(BasementServer).Assembly;
        var enabled = new List<string>();
        foreach (var p in patches)
        {
            if (p is not AbstractPatch ap || ap.GetType().Assembly != mine) continue;
            try { if (!ap.IsActive) ap.Enable(); enabled.Add(ap.GetType().Name); }
            catch (Exception ex) { logger.Error("[Basement.Server] enabling " + ap.GetType().Name + " FAILED: " + ex.Message, null); }
        }
        var status = sidecar.Get("/status");
        logger.Success("[Basement.Server] v" + Assembly.GetExecutingAssembly().GetName().Version + " config=" + source +
                       " sidecar=" + cfg.SidecarUrl + (status != null ? " (answers /status)" : " (NOT answering /status -- every hook falls back to SPT until it does)") +
                       " patches=" + string.Join(",", enabled), null);
        return Task.CompletedTask;
    }
}
