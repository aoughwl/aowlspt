using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading.Tasks;
using Aowl.Api;
using Comfort.Common;
using EFT;
using EFT.Game.Spawning;
using HarmonyLib;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The `group.spawn` actuator: materialise the backend's people mid-raid through the
    /// client's own spawner. Every game member below was verified offline against
    /// Assembly-CSharp 4.1.5 with MemberCheck (docs/SPT415-BOT-CONTROL.md, section 2b);
    /// NONE of it has run in a live client yet, and the doc says so.
    ///
    /// Directive (CLIENT-CONTRACT.md): {factionId, count, near{map,x,y,z}, radiusM,
    /// people:[{id,name,role,voice,loadoutNote}]} plus two additive fields this client
    /// reads: `role` (a WildSpawnType name; overrides the factionId map) and
    /// `mode` ("positions" default when `near` is present, else "anywhere").
    ///
    /// Two paths, both public game API:
    ///   anywhere  : BotSpawner.SpawnBotByTypeForce(count, WildSpawnType, BotDifficulty, BotSpawnParams)
    ///               -- SPT's own zone choice; the bots come back through /client/game/bot/generate,
    ///               where Basement.Server names them from the backend plan.
    ///   positions : BotCreationData.Create(IGetProfileData, IBotCreator, count, ITokenGetter) then
    ///               BotSpawner.SpawnBotsInZoneOnPositions(List&lt;ISpawnPoint&gt;, BotZone, data, callback)
    ///               with our own ISpawnPoint rows at the scene coordinates.
    /// The ack means ACCEPTED (the spawn is queued); materialisation is reported by
    /// `bot.created` observes, one per bot, when the spawner's callback fires.
    /// </summary>
    internal static class GroupSpawn
    {
        public static int Accepted, Refused, Created;

        public static void Install()
        {
            AowlEvents.Directives.Register("group.spawn", e => { if (e.WantsAck) OnDirective(e); });
        }

        private static readonly Dictionary<string, WildSpawnType> FactionRole = new Dictionary<string, WildSpawnType>(StringComparer.OrdinalIgnoreCase)
        {
            { "scav", WildSpawnType.assault }, { "savage", WildSpawnType.assault }, { "assault", WildSpawnType.assault },
            { "bear", WildSpawnType.pmcBEAR }, { "usec", WildSpawnType.pmcUSEC }, { "pmc", WildSpawnType.pmcUSEC },
            { "raider", WildSpawnType.pmcBot }, { "rogue", WildSpawnType.exUsec }, { "cultist", WildSpawnType.sectantWarrior },
            { "guard", WildSpawnType.assault },
        };

        private static void OnDirective(AowlEvent e)
        {
            string why;
            try { why = Execute(e); }
            catch (Exception ex) { why = "group.spawn threw " + ex.GetType().Name + ": " + ex.Message; }
            if (why == null) { Accepted++; e.Ack(true, "accepted"); }
            else { Refused++; Plugin.Log.LogWarning("basement group.spawn REFUSED: " + why); e.Ack(false, why); }
        }

        /// <summary>null = accepted; otherwise the measured reason.</summary>
        private static string Execute(AowlEvent e)
        {
            var d = e.Data;
            var count = d.Value<int?>("count") ?? 0;
            if (count < 1) return "count < 1";
            if (count > 16) count = 16;
            var factionId = d.Value<string>("factionId") ?? "";
            var roleName = d.Value<string>("role") ?? "";
            WildSpawnType role;
            if (roleName.Length > 0)
            {
                if (!Enum.TryParse(roleName, true, out role)) return "role `" + roleName + "` is not a WildSpawnType on this build";
            }
            else if (!FactionRole.TryGetValue(factionId, out role)) return "factionId `" + factionId + "` has no role mapping and no `role` was given";

            if (!Singleton<IBotGame>.Instantiated) return "no IBotGame -- not in a raid";
            var game = Singleton<IBotGame>.Instance;
            var bc = game?.BotsController;
            var spawner = bc?.BotSpawner;
            if (spawner == null) return "BotsController.BotSpawner is null -- the raid has no spawner yet";

            var near = d["near"] as JObject;
            var mode = d.Value<string>("mode") ?? (near != null ? "positions" : "anywhere");
            var difficulty = ParseDifficulty(d.Value<string>("difficulty"));
            var side = role == WildSpawnType.pmcBEAR ? EPlayerSide.Bear : role == WildSpawnType.pmcUSEC ? EPlayerSide.Usec : EPlayerSide.Savage;

            if (mode == "anywhere")
            {
                var task = spawner.SpawnBotByTypeForce(count, role, difficulty, new BotSpawnParams());
                Observe(task, "SpawnBotByTypeForce", count, role);
                Plugin.Log.LogInfo("basement group.spawn: queued " + count + "x " + role + " via SpawnBotByTypeForce (zone chosen by the game).");
                return null;
            }
            if (near == null) return "mode `positions` needs `near{x,y,z}`";
            var center = new Vector3(near.Value<float?>("x") ?? 0f, near.Value<float?>("y") ?? 0f, near.Value<float?>("z") ?? 0f);
            var radius = Mathf.Clamp(d.Value<float?>("radiusM") ?? 4f, 1f, 30f);

            float dist;
            var zone = spawner.GetClosestZone(center, out dist);
            if (zone == null) return "GetClosestZone returned null for " + center;
            var creator = AccessTools.Field(typeof(BotSpawner), "_botCreator")?.GetValue(spawner) as IBotCreator;
            if (creator == null) return "BotSpawner._botCreator did not read back as IBotCreator";

            var profileData = new GetProfileDataParams(side, role, difficulty, 0f, new BotSpawnParams(), false);
            var points = new List<ISpawnPoint>();
            var corePointId = NearestCorePointId(zone, center);
            for (var i = 0; i < count; i++)
            {
                var a = i * 2f * Mathf.PI / count;
                var p = center + new Vector3(Mathf.Cos(a), 0f, Mathf.Sin(a)) * (count == 1 ? 0f : radius);
                if (BotZone.IsOnNavMesh(p) == false)
                    Plugin.Log.LogWarning("basement group.spawn: point " + p + " is NOT on the navmesh (BotZone.IsOnNavMesh) -- kept, the spawner will say what it does with it.");
                points.Add(new ScenePoint("basement-" + e.Seq + "-" + i, p, zone.NameZone, corePointId));
            }
            var seq = e.Seq;
            RunPositions(profileData, creator, spawner, zone, points, count, role, seq);
            Plugin.Log.LogInfo("basement group.spawn: creating " + count + "x " + role + " at " + center + " r=" + radius + " zone=" + zone.NameZone + " (dist " + dist.ToString("0.0") + "m).");
            return null;
        }

        private static async void RunPositions(IGetProfileData profileData, IBotCreator creator, BotSpawner spawner, BotZone zone, List<ISpawnPoint> points, int count, WildSpawnType role, long seq)
        {
            try
            {
                // ITokenGetter: EFT.BotSpawner implements it (measured impl list).
                var data = await BotCreationData.Create(profileData, creator, count, spawner);
                if (data == null) { Plugin.Log.LogWarning("basement group.spawn seq " + seq + ": BotCreationData.Create returned null -- nothing spawned."); Observe("bot.spawn.failed", seq, role, "Create returned null"); return; }
                Plugin.Log.LogInfo("basement group.spawn seq " + seq + ": profiles loaded (" + data.Profiles?.Count + "), spawning on " + points.Count + " positions.");
                spawner.SpawnBotsInZoneOnPositions(points, zone, data, bot =>
                {
                    Created++;
                    var nick = bot?.Profile?.Info?.Nickname ?? "?";
                    Plugin.Log.LogInfo("basement group.spawn seq " + seq + ": bot created `" + nick + "` role " + role + " at " + (bot != null ? bot.Position.ToString() : "?"));
                    var o = new JObject { ["seq"] = seq, ["nickname"] = nick, ["profileId"] = bot?.ProfileId ?? "", ["role"] = role.ToString() };
                    AowlEvents.Link.Observe("bot.created", o);
                });
            }
            catch (Exception ex)
            {
                Plugin.Log.LogError("basement group.spawn seq " + seq + " FAILED in the spawner: " + ex);
                Observe("bot.spawn.failed", seq, role, ex.GetType().Name + ": " + ex.Message);
            }
        }

        private static void Observe(Task task, string how, int count, WildSpawnType role)
        {
            if (task == null) return;
            task.ContinueWith(t =>
            {
                if (t.IsFaulted) Plugin.OnMain(() => Plugin.Log.LogError("basement group.spawn " + how + " faulted: " + t.Exception?.GetBaseException()));
                else Plugin.OnMain(() => Plugin.Log.LogInfo("basement group.spawn " + how + " completed for " + count + "x " + role + "."));
            });
        }

        private static void Observe(string kind, long seq, WildSpawnType role, string note)
        {
            AowlEvents.Link.Observe(kind, new JObject { ["seq"] = seq, ["role"] = role.ToString(), ["note"] = note });
        }

        private static BotDifficulty ParseDifficulty(string s)
        {
            BotDifficulty d;
            return s != null && Enum.TryParse(s, true, out d) ? d : BotDifficulty.normal;
        }

        private static int NearestCorePointId(BotZone zone, Vector3 at)
        {
            var best = 0; var bestD = float.MaxValue;
            var pts = zone?.SpawnPoints;
            if (pts == null) return 0;
            foreach (var sp in pts)
            {
                if (sp == null) continue;
                var dd = (sp.Position - at).sqrMagnitude;
                if (dd < bestD) { bestD = dd; best = sp.CorePointId; }
            }
            return best;
        }

        /// <summary>Our ISpawnPoint at a scene coordinate. Every member of EFT.Game.Spawning.ISpawnPoint
        /// on 4.1.5 is implemented (15 properties, 5 methods, measured). Collider is null on purpose:
        /// if the spawner dereferences it that is the first thing the live test will say.</summary>
        private sealed class ScenePoint : ISpawnPoint
        {
            private readonly string _id; private readonly Vector3 _pos; private readonly string _zone;
            public ScenePoint(string id, Vector3 pos, string zone, int corePointId) { _id = id; _pos = pos; _zone = zone; CorePointId = corePointId; }
            public string Id => _id;
            public string Name => _id;
            public bool SpawnBlocked { get; set; }
            public Vector3 Position => _pos;
            public Quaternion Rotation => Quaternion.identity;
            public EPlayerSideMask Sides => EPlayerSideMask.All;
            public ESpawnCategoryMask Categories => ESpawnCategoryMask.Bot;
            public string Infiltration => "";
            public string BotZoneName => _zone;
            public bool IsSnipeZone => false;
            public float DelayToCanSpawnSec => 0f;
            public float NextBornTime { get; set; }
            public int CorePointId { get; set; }
            public ISpawnPointCollider Collider => null;
            public float CalcMultiSpawnDelay(float additionalDelay, BotCreationData creationData) => additionalDelay;
            public void Dispose() { }
            public bool IsNotCollidedArtillery(ArtilleryShellingControllerServer artilleryShelling) => true;
            public bool IsInPlayersIndividualLimits(BotCreationData creationData) => true;
            public void IncreaseUsedPlayerSpawnsForNearestPlayer(BotCreationData creationData) { }
        }
    }
}
