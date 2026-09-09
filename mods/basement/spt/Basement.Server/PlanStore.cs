using System.Collections.Concurrent;

namespace Basement.Server;

/// <summary>One planned bot, dequeued in generation order per (session, role).</summary>
public sealed record PlannedBot(string Name, string? PersonId, string GroupId, string? Loadout, string? Side, string? Difficulty);

/// <summary>Per-session queues of planned bots keyed by the ROLE the client asked for.
/// Filled by GenerateBotsPatch (one sidecar call per /client/game/bot/generate), peeked
/// by GenerateInventoryPatch (loadout swap) and popped by PrepareAndGenerateBotPatch
/// (name). Peek and pop must agree, and they do because GenerateBot calls
/// GenerateInventory exactly once per bot (measured: the only call site).</summary>
public static class PlanStore
{
    private static readonly ConcurrentDictionary<string, ConcurrentDictionary<string, ConcurrentQueue<PlannedBot>>> Sessions = new();
    public static readonly ConcurrentDictionary<string, int> WaveCounter = new();
    public static int Planned, Named, LoadoutSwapped, Unplanned;

    public static int NextWave(string session) => WaveCounter.AddOrUpdate(session, 1, (_, n) => n + 1);

    public static void Fill(string session, IEnumerable<PlannedGroup> groups)
    {
        var roles = Sessions.GetOrAdd(session, _ => new ConcurrentDictionary<string, ConcurrentQueue<PlannedBot>>(StringComparer.OrdinalIgnoreCase));
        foreach (var g in groups)
        {
            var q = roles.GetOrAdd(string.IsNullOrEmpty(g.Role) ? "assault" : g.Role, _ => new ConcurrentQueue<PlannedBot>());
            var n = Math.Max(g.Count, g.Names.Count);
            for (var i = 0; i < n; i++)
            {
                var name = i < g.Names.Count ? g.Names[i] : "";
                var pid = g.PersonIds != null && i < g.PersonIds.Count ? g.PersonIds[i] : null;
                q.Enqueue(new PlannedBot(name, pid, g.GroupId, g.Loadout, g.Side, g.Difficulty));
                Planned++;
            }
        }
    }

    public static PlannedBot? Peek(string session, string role)
    {
        if (!Sessions.TryGetValue(session, out var roles) || !roles.TryGetValue(role, out var q)) return null;
        return q.TryPeek(out var b) ? b : null;
    }

    public static PlannedBot? Pop(string session, string role)
    {
        if (!Sessions.TryGetValue(session, out var roles) || !roles.TryGetValue(role, out var q)) return null;
        return q.TryDequeue(out var b) ? b : null;
    }

    public static int Pending(string session)
    {
        if (!Sessions.TryGetValue(session, out var roles)) return 0;
        return roles.Values.Sum(q => q.Count);
    }

    public static object Snapshot() => new
    {
        planned = Planned, named = Named, loadoutSwapped = LoadoutSwapped, unplanned = Unplanned,
        sessions = Sessions.ToDictionary(k => k.Key, v => v.Value.ToDictionary(r => r.Key, r => r.Value.Count)),
        waves = WaveCounter.ToDictionary(k => k.Key, v => v.Value),
    };
}
