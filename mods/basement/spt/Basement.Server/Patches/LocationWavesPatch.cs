using System.Reflection;
using System.Text.Json;
using HarmonyLib;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;
using SPTarkov.Reflection.Patching;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Eft.Common;
using SPTarkov.Server.Core.Services.InRaid;
using SPTarkov.Server.Core.Utils;

namespace Basement.Server.Patches;

/// <summary>Postfix on LocationLifecycleService.GenerateLocationAndLoot(MongoId, string, bool)
/// -> LocationBase, the per-raid clone that StartLocalRaidAsync serves as
/// StartLocalRaidResponseData.LocationLoot (measured call chain). It runs AFTER SPT's own
/// PmcWaveGenerator and RaidTimeAdjustmentService.MakeAdjustmentsToMap, so what we write
/// is what the client's WavesSpawnScenario / BossSpawnScenario receives.
/// GET /aowlspt/basement/spt/waves?map=ID answers {ok, clear, waves:[EFT wave], bossWaves:[EFT BossLocationSpawn]}.
/// Rows are parsed by SPT's JsonUtil into SPT's own Wave / BossLocationSpawn records, and a
/// wave naming a zone the location does not list in SpawnPointParams is DROPPED loudly.</summary>
[Injectable]
public sealed class LocationWavesPatch : AbstractPatch
{
    private static Sidecar? _sidecar;
    private static ISptLogger<LocationWavesPatch>? _log;
    private static JsonUtil? _json;
    public static int WavesWritten, BossWavesWritten, WavesDropped;

    public LocationWavesPatch(Sidecar sidecar, ISptLogger<LocationWavesPatch> log, JsonUtil json) : base("Basement.LocationWaves")
    {
        _sidecar = sidecar; _log = log; _json = json;
    }

    protected override MethodBase GetTargetMethod() => AccessTools.Method(typeof(LocationLifecycleService), nameof(LocationLifecycleService.GenerateLocationAndLoot));

    [PatchPostfix]
    public static void Postfix(MongoId sessionId, string name, LocationBase __result)
    {
        try { Run(sessionId, name, __result); }
        catch (Exception ex) { _log?.Error("[Basement.Server] LocationWaves postfix threw -- SPT waves kept: " + ex, null); }
    }

    private static void Run(MongoId sessionId, string name, LocationBase loc)
    {
        var s = _sidecar; if (s == null || !s.Cfg.Enabled || !s.Cfg.RewriteWaves || loc == null) return;
        var map = loc.Id ?? name;
        var resp = s.Parse<WavesResponse>(s.Get("/spt/waves?map=" + Uri.EscapeDataString(map) + "&raidId=" + Uri.EscapeDataString(sessionId.ToString())), "GET /spt/waves");
        if (resp == null) return;
        if (!resp.Ok) { _log?.Info("[Basement.Server] backend has no wave plan for `" + map + "`: " + (resp.Note ?? "no note"), null); return; }

        var zones = new HashSet<string>(StringComparer.Ordinal);
        foreach (var p in loc.SpawnPointParams ?? Enumerable.Empty<SpawnPointParam>())
            if (!string.IsNullOrEmpty(p.BotZoneName)) zones.Add(p.BotZoneName);

        var waves = ParseList<Wave>(resp.Waves, "waves");
        var boss = ParseList<BossLocationSpawn>(resp.BossWaves, "bossWaves");
        if (waves == null && boss == null && !resp.Clear) return;

        if (resp.Clear)
        {
            _log?.Info("[Basement.Server] `" + map + "`: backend CLEARED " + (loc.Waves?.Count ?? 0) + " waves and " + (loc.BossLocationSpawn?.Count ?? 0) + " boss spawns.", null);
            loc.Waves = new List<Wave>();
            loc.BossLocationSpawn = new List<BossLocationSpawn>();
        }
        loc.Waves ??= new List<Wave>();
        loc.BossLocationSpawn ??= new List<BossLocationSpawn>();

        var added = 0;
        foreach (var w in waves ?? new List<Wave>())
        {
            var zone = w.SpawnPoints ?? "";
            if (zone.Length > 0 && zones.Count > 0 && !zones.Contains(zone))
            {
                WavesDropped++;
                _log?.Warning("[Basement.Server] `" + map + "`: wave zone `" + zone + "` is not a BotZoneName of this location (" + zones.Count + " known) -- wave DROPPED, not guessed.", null);
                continue;
            }
            loc.Waves.Add(w); added++; WavesWritten++;
        }
        var addedBoss = 0;
        foreach (var b in boss ?? new List<BossLocationSpawn>())
        {
            var zone = b.BossZone ?? "";
            if (zone.Length > 0 && zones.Count > 0 && !zone.Split(',').Select(z => z.Trim()).All(zones.Contains))
            {
                WavesDropped++;
                _log?.Warning("[Basement.Server] `" + map + "`: boss zone `" + zone + "` is not a BotZoneName of this location -- boss wave DROPPED.", null);
                continue;
            }
            loc.BossLocationSpawn.Add(b); addedBoss++; BossWavesWritten++;
        }
        _log?.Info("[Basement.Server] `" + map + "`: wrote " + added + " waves + " + addedBoss + " boss spawns from the backend; location now serves " + loc.Waves.Count + " waves, " + loc.BossLocationSpawn.Count + " boss spawns.", null);
    }

    private static List<T>? ParseList<T>(JsonElement? el, string what) where T : class
    {
        if (el == null || el.Value.ValueKind != JsonValueKind.Array) return null;
        try { return _json?.Deserialize<List<T>>(el.Value.GetRawText()); }
        catch (Exception ex) { _log?.Warning("[Basement.Server] " + what + " rows do not parse as SPT " + typeof(T).Name + " (" + ex.Message + ") -- ignored.", null); return null; }
    }
}
