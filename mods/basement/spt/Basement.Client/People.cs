using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Comfort.Common;
using EFT;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The backend population (GET /world/people) and the client-owned map
    /// personId -> live bot (CLIENT-CONTRACT section 6.2). A person that is
    /// not mapped is not addressable and is never named in a fact.
    ///
    /// In 0.1.0 nothing spawns bots on request (group.spawn is acked ok:false),
    /// so the only mapping is the HEURISTIC in MatchByNickname: a live bot whose
    /// profile nickname equals a person's name. It is config-gated, logged on
    /// every bind, and called a heuristic in the log.
    /// </summary>
    internal static class People
    {
        public sealed class Person
        {
            public string Id, Name, FactionId, Role, Voice, Map, Activity, Attitude;
            public float X, Y, Z;
            public bool Alive;
        }

        private static readonly Dictionary<string, Person> Known = new Dictionary<string, Person>(StringComparer.Ordinal);
        private static readonly Dictionary<string, Player> Bots = new Dictionary<string, Player>(StringComparer.Ordinal);      // personId -> bot
        private static readonly Dictionary<string, string> ByProfile = new Dictionary<string, string>(StringComparer.Ordinal); // profileId -> personId
        private static readonly object Gate = new object();
        public static int Refreshes, Binds;
        public static float LastRefreshAt = -1e9f;

        public static Person Get(string id) { lock (Gate) return id != null && Known.TryGetValue(id, out var p) ? p : null; }
        public static Player BotFor(string personId) { lock (Gate) return personId != null && Bots.TryGetValue(personId, out var b) ? b : null; }
        public static string PersonFor(string profileId) { lock (Gate) return profileId != null && ByProfile.TryGetValue(profileId, out var id) ? id : null; }
        public static string PersonFor(Player p) => p == null ? null : PersonFor(p.ProfileId);
        public static string NameOf(string personId) => Get(personId)?.Name ?? personId;
        public static int MappedCount { get { lock (Gate) return Bots.Count; } }
        public static int KnownCount { get { lock (Gate) return Known.Count; } }

        public static List<KeyValuePair<string, Player>> Mapped()
        {
            lock (Gate) return new List<KeyValuePair<string, Player>>(Bots);
        }

        public static void Bind(string personId, Player bot, string how)
        {
            if (personId == null || bot == null) return;
            lock (Gate)
            {
                Bots[personId] = bot;
                ByProfile[bot.ProfileId] = personId;
            }
            Binds++;
            Plugin.Log.LogInfo("basement people: person " + personId + " (" + NameOf(personId) + ") -> bot " + bot.ProfileId + " [" + how + "]");
            See.OnBotBound(personId, bot);
        }

        public static void Unbind(string personId)
        {
            lock (Gate)
            {
                if (Bots.TryGetValue(personId, out var b) && b != null) ByProfile.Remove(b.ProfileId);
                Bots.Remove(personId);
            }
        }

        public static void ClearBots() { lock (Gate) { Bots.Clear(); ByProfile.Clear(); } }

        /// <summary>Background thread. Reads /world/people and replaces the known set.</summary>
        public static void RefreshSync(string map, Vector3? near = null, float radius = 0)
        {
            var url = Http.Route("/world/people");
            var q = new List<string>();
            if (!string.IsNullOrEmpty(map)) q.Add("map=" + Uri.EscapeDataString(map));
            if (near.HasValue) q.Add("near=" + F(near.Value.x) + "," + F(near.Value.y) + "," + F(near.Value.z));
            if (radius > 0) q.Add("radius=" + ((int)radius));
            if (q.Count > 0) url += "?" + string.Join("&", q);
            var r = Http.Get(url, 10000);
            if (!r.Ok)
            {
                if (Plugin.Once("people-fail:" + r.Status)) Plugin.Log.LogWarning("basement people: GET /world/people answered " + r.Err);
                return;
            }
            var arr = r.Json["people"] as JArray;
            var next = new Dictionary<string, Person>(StringComparer.Ordinal);
            if (arr != null)
                foreach (var t in arr)
                {
                    var o = t as JObject; if (o == null) continue;
                    var id = o.Value<string>("id"); if (string.IsNullOrEmpty(id)) continue;
                    next[id] = new Person
                    {
                        Id = id, Name = o.Value<string>("name") ?? id, FactionId = o.Value<string>("factionId") ?? "",
                        Role = o.Value<string>("role") ?? "", Voice = o.Value<string>("voice") ?? "", Map = o.Value<string>("map") ?? "",
                        Activity = o.Value<string>("activity") ?? "", Attitude = o.Value<string>("attitude") ?? "",
                        X = o.Value<float?>("x") ?? 0, Y = o.Value<float?>("y") ?? 0, Z = o.Value<float?>("z") ?? 0,
                        Alive = o.Value<bool?>("alive") ?? true,
                    };
                }
            lock (Gate)
            {
                Known.Clear();
                foreach (var kv in next) Known[kv.Key] = kv.Value;
            }
            Refreshes++;
            LastRefreshAt = Time.realtimeSinceStartup;
        }

        public static void Refresh(string map, Vector3? near = null, float radius = 0)
        {
            LastRefreshAt = Time.realtimeSinceStartup; // rate-limit from the caller's clock, not the completion's
            Task.Run(() => RefreshSync(map, near, radius));
        }

        /// <summary>Main thread. The heuristic mapping, by nickname. Says what it did.</summary>
        public static void MatchByNickname(GameWorld gw)
        {
            if (!Plugin.MatchPeopleByName.Value || gw == null) return;
            var list = gw.AllAlivePlayersList;
            if (list == null) return;
            List<Person> people;
            lock (Gate) people = new List<Person>(Known.Values);
            foreach (var p in list)
            {
                if (p == null || p.IsYourPlayer) continue;
                if (PersonFor(p.ProfileId) != null) continue;
                string nick = null;
                try { nick = p.Profile?.Info?.Nickname; } catch { }
                if (string.IsNullOrEmpty(nick)) continue;
                foreach (var person in people)
                {
                    if (BotFor(person.Id) != null) continue;
                    if (string.Equals(person.Name, nick, StringComparison.OrdinalIgnoreCase))
                    {
                        Bind(person.Id, p, "HEURISTIC nickname match");
                        break;
                    }
                }
            }
        }

        private static string F(float v) => v.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture);
    }
}
