using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Aowl.Api;
using Comfort.Common;
using EFT;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The backend population (AowlWorld.People -> GET /world/people) and the
    /// client-owned map personId -> live bot (CLIENT-CONTRACT section 6.2). A
    /// person that is not mapped is not addressable and is never named in a
    /// fact.
    ///
    /// In 0.1.0 nothing spawns bots on request (group.spawn is acked ok:false),
    /// so the only mapping is the HEURISTIC in MatchByNickname: a live bot whose
    /// profile nickname equals a person's name. It is config-gated, logged on
    /// every bind, and called a heuristic in the log.
    /// </summary>
    internal static class People
    {
        /// <summary>The API's typed person record, as this client keeps it.</summary>
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

        /// <summary>Background thread. Reads /world/people through the API and replaces the known set.</summary>
        public static void RefreshSync(string map, Vector3? near = null, float radius = 0)
        {
            var r = near.HasValue
                ? AowlWorld.People(map, near.Value.x, near.Value.y, near.Value.z, radius)
                : AowlWorld.People(map, null, null, null, radius);
            if (!r.Ok)
            {
                if (Plugin.Once("people-fail:" + r.Error)) Plugin.Log.LogWarning("basement people: " + r.Error);
                return;
            }
            var next = new Dictionary<string, Person>(StringComparer.Ordinal);
            foreach (var p in r.Value)
                next[p.Id] = new Person
                {
                    Id = p.Id, Name = p.Name, FactionId = p.Faction, Role = p.Role, Voice = p.Voice, Map = p.Map,
                    Activity = p.Activity, Attitude = p.Attitude, X = p.X, Y = p.Y, Z = p.Z, Alive = p.Alive,
                };
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


        /// <summary>
        /// Main thread. The FALLBACK binder, needed because SPT's bots carry random
        /// nicknames, so MatchByNickname binds nothing in an ordinary raid (MEASURED
        /// 2026-09-07, first live run: 0 binds, no player_seen ever). Every live,
        /// unmapped bot is bound to the nearest still-unbound world person on THIS
        /// map; when the world has nobody left on this map, to any unbound person,
        /// and the log says the person was relocated. The world's positions are
        /// its own fiction; the bot is where the person IS for this raid.
        /// </summary>
        public static void MatchByProximity(GameWorld gw, Vector3 mainPos, string map)
        {
            if (!Plugin.BindUnmatchedBots.Value || gw == null) return;
            var list = gw.AllAlivePlayersList;
            if (list == null) return;
            List<Person> people;
            lock (Gate) people = new List<Person>(Known.Values);
            foreach (var p in list)
            {
                if (p == null || p.IsYourPlayer) continue;
                if (PersonFor(p.ProfileId) != null) continue;
                Person best = null; float bestD = float.MaxValue; bool bestSameMap = false;
                foreach (var person in people)
                {
                    if (!person.Alive || BotFor(person.Id) != null) continue;
                    bool same = string.Equals(person.Map, map, StringComparison.OrdinalIgnoreCase);
                    float d = same ? Vector3.Distance(p.Position, new Vector3(person.X, person.Y, person.Z)) : float.MaxValue / 2;
                    if (best == null || (same && !bestSameMap) || (same == bestSameMap && d < bestD))
                    { best = person; bestD = d; bestSameMap = same; }
                }
                if (best == null)
                {
                    if (Plugin.Once("no-unbound-people")) Plugin.Log.LogWarning("basement people: a live bot has no world person left to be -- the world's population (" + people.Count + ") is exhausted on this raid; further bots stay unmapped.");
                    return;
                }
                Bind(best.Id, p, bestSameMap
                    ? "FALLBACK nearest unbound person on " + map + " (" + F(bestD) + " m from the world's position)"
                    : "FALLBACK relocated from " + best.Map + " -- the world had nobody left on " + map);
            }
        }

        private static string F(float v) => v.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture);
    }
}
