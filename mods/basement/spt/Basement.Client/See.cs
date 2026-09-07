using System;
using System.Collections.Generic;
using Comfort.Common;
using EFT;
using EFT.HealthSystem;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The facts this client can measure (CLIENT-CONTRACT section 2), from the
    /// Mono-visible game objects. Every member used here was checked against
    /// Assembly-CSharp 4.1.5 with Mono.Cecil (see README, "verified members").
    ///
    ///   raid_started / raid_ended   Singleton&lt;GameWorld&gt;.Instantiated + MainPlayer transitions;
    ///                               the reason comes from TarkovApplication.ShowSessionResult's ExitStatus
    ///                               (Harmony prefix in Spawn) or a seen player_died, else "disconnect".
    ///   tick                        1 Hz in raid.
    ///   player_moved                every 2 s in raid, and once right after raid_started.
    ///   player_seen / player_lost   MAPPED people, alive, within NoticeM, inside 35 deg of the camera forward.
    ///                               RE-SENT for someone already in view when their distance has moved
    ///                               2 m or more and 0.5 s has passed. That is not noise: the backend's
    ///                               `approach` and `push` triggers are derived from CONSECUTIVE
    ///                               distances, and with the old edge-only report there was never a
    ///                               second sample to derive them from.
    ///   npc_moved                   every 2 s, ONE batched POST carrying every BOUND person's position,
    ///                               so the backend can decide who is close enough to be heard.
    ///   player_aimed_at             HandsController.IsAiming held 400 ms with an addressee.
    ///   player_lowered_weapon       not aiming for 1 s after an aimed episode.
    ///   player_fired                FirearmController.OnShot (hit is NOT known: hitKnown:false is sent).
    ///   player_hit                  ActiveHealthController.ApplyDamageEvent; hp is HealthController.HealthRate,
    ///                               whose semantics are UNVERIFIED (hpSource names it).
    ///   player_died / npc_died      Player.OnPlayerDead on the main player and on every mapped bot.
    /// </summary>
    internal static class See
    {
        public static float NoticeM = 25f;
        private const float ConeDeg = 35f;
        private const float MovedEvery = 2f;
        private const float TickEvery = 1f;
        private const float ScanEvery = 0.1f;
        private const float SeenRefreshEvery = 0.5f;
        private const float SeenRefreshM = 2f;
        private const float PeopleEvery = 10f;
        private const float AimHold = 0.4f;
        private const float LowerHold = 1f;

        public static bool InRaid;
        public static string Map = "";
        public static string Addressee;            // the person the player would talk to right now
        public static int RaidStarts, RaidEnds, Seen, Lost, Aimed, Fired, Hits, Ticks, Moves;
        public static int RaidsEnded => RaidEnds;

        private static Player _main;
        private static object _hands;             // the HandsController we subscribed OnShot on
        private static Player.FirearmController _firearm;
        private static float _lastScan, _lastTick, _lastMove, _lastPeople;
        private static float _aimSince = -1f, _notAimSince = -1f;
        private static bool _aimSent, _lowerPending;
        private static string _exitStatus;
        private static bool _mainDied;
        private static readonly HashSet<string> InView = new HashSet<string>(StringComparer.Ordinal);
        // What we last TOLD the backend about each in-view person, so a refresh
        // is sent on a real change and not on every 0.1 s scan.
        private static readonly Dictionary<string, float> SentDist = new Dictionary<string, float>(StringComparer.Ordinal);
        private static readonly Dictionary<string, float> SentAt = new Dictionary<string, float>(StringComparer.Ordinal);
        public static int SeenRefreshes, NpcMoves;
        private static readonly HashSet<string> Subscribed = new HashSet<string>(StringComparer.Ordinal);

        private static readonly Comparison<Candidate> ByRank = (a, b) =>
        {
            int c = a.Dist.CompareTo(b.Dist); if (c != 0) return c;
            c = a.Angle.CompareTo(b.Angle); if (c != 0) return c;
            return string.CompareOrdinal(a.Id, b.Id);
        };
        private struct Candidate { public string Id; public float Dist; public float Angle; }

        public static void OnExitStatus(string status) { _exitStatus = status; }

        public static void Tick()
        {
            if (!Plugin.Started) return;
            float now = Time.realtimeSinceStartup;
            if (now - _lastScan < ScanEvery) return;
            _lastScan = now;

            GameWorld gw = Singleton<GameWorld>.Instantiated ? Singleton<GameWorld>.Instance : null;
            Player main = gw != null ? gw.MainPlayer : null;
            bool nowIn = gw != null && main != null;

            if (nowIn && !InRaid) Enter(gw, main, now);
            else if (!nowIn && InRaid) Leave();
            if (!InRaid) return;
            if (main != _main) { _main = main; }

            if (now - _lastTick >= TickEvery)
            {
                _lastTick = now; Ticks++;
                Plugin.Link.Observe("tick", new JObject { ["nowMs"] = (long)(now * 1000) });
            }
            if (now - _lastMove >= MovedEvery) { _lastMove = now; SendMoved(main); SendNpcMoved(gw); }
            if (now - _lastPeople >= PeopleEvery)
            {
                _lastPeople = now;
                People.Refresh("", null, 0); // whole population: the fallback binder relocates people from other maps (MEASURED 2026-09-07: factory had 0 of 40)
                People.MatchByNickname(gw);
                People.MatchByProximity(gw, main.Position, Map);
            }
            WatchHands(main);
            ScanView(gw, main, now);
            WatchAim(main, now);
        }

        private static void Enter(GameWorld gw, Player main, float now)
        {
            InRaid = true;
            RaidStarts++;
            _main = main;
            _exitStatus = null;
            _mainDied = false;
            InView.Clear();
            SentDist.Clear();
            SentAt.Clear();
            Addressee = null;
            Map = gw.LocationId ?? "";
            var p = main.Position;
            Plugin.Log.LogInfo("basement see: raid started on " + Map + " at " + p);
            Plugin.Link.Observe("raid_started", new JObject { ["map"] = Map, ["spawnX"] = p.x, ["spawnY"] = p.y, ["spawnZ"] = p.z });
            try
            {
                main.OnPlayerDead += OnMainDead;
                var ahc = main.ActiveHealthController;
                if (ahc != null) ahc.ApplyDamageEvent += OnMainDamaged;
                else if (Plugin.Once("no-ahc")) Plugin.Log.LogWarning("basement see: MainPlayer.ActiveHealthController is null; player_hit is OFF this raid.");
            }
            catch (Exception ex) { Plugin.Log.LogWarning("basement see: subscribing main-player events threw " + ex.Message); }
            _lastPeople = now;
            People.Refresh("", null, 0);
            People.MatchByNickname(gw);
            People.MatchByProximity(gw, p, Map);
            _lastMove = now;
            SendMoved(main);
        }

        private static void Leave()
        {
            InRaid = false;
            RaidEnds++;
            string reason;
            if (_mainDied || _exitStatus == "Killed") reason = "death";
            else if (_exitStatus == "Survived" || _exitStatus == "Transit") reason = "extract";
            else reason = "disconnect";
            Plugin.Log.LogInfo("basement see: raid ended (" + reason + "; ExitStatus=" + (_exitStatus ?? "not observed") + ")");
            var o = new JObject { ["reason"] = reason };
            if (_exitStatus != null) o["exitStatus"] = _exitStatus;
            Plugin.Link.Observe("raid_ended", o);
            try
            {
                if (_main != null)
                {
                    _main.OnPlayerDead -= OnMainDead;
                    var ahc = _main.ActiveHealthController;
                    if (ahc != null) ahc.ApplyDamageEvent -= OnMainDamaged;
                }
                if (_firearm != null) _firearm.OnShot -= OnShot;
            }
            catch { }
            _main = null; _hands = null; _firearm = null;
            foreach (var id in InView) Plugin.Link.Observe("player_lost", new JObject { ["personId"] = id });
            InView.Clear();
            SentDist.Clear();
            SentAt.Clear();
            Subscribed.Clear();
            People.ClearBots();
            Addressee = null;
            _aimSince = -1f; _aimSent = false; _lowerPending = false;
        }

        // ------------------------------------------------------------ hands, shots, aim

        private static void WatchHands(Player main)
        {
            object hc = null;
            try { hc = main.HandsController; } catch { }
            if (ReferenceEquals(hc, _hands)) return;
            if (_firearm != null) { try { _firearm.OnShot -= OnShot; } catch { } _firearm = null; }
            _hands = hc;
            _firearm = hc as Player.FirearmController;
            if (_firearm != null) _firearm.OnShot += OnShot;
        }

        private static void OnShot()
        {
            Fired++;
            Plugin.Link.Observe("player_fired", new JObject { ["at"] = Addressee ?? "", ["hit"] = false, ["hitKnown"] = false });
        }

        private static void WatchAim(Player main, float now)
        {
            bool aiming = false;
            try { aiming = main.HandsController != null && main.HandsController.IsAiming; } catch { }
            if (aiming)
            {
                _notAimSince = -1f;
                if (_aimSince < 0) { _aimSince = now; _aimSent = false; }
                if (!_aimSent && Addressee != null && now - _aimSince >= AimHold)
                {
                    _aimSent = true; _lowerPending = true; Aimed++;
                    float d = 0f;
                    var bot = People.BotFor(Addressee);
                    if (bot != null) d = Vector3.Distance(main.Position, bot.Position);
                    Plugin.Link.Observe("player_aimed_at", new JObject { ["personId"] = Addressee, ["distanceM"] = d });
                }
            }
            else
            {
                _aimSince = -1f;
                if (_notAimSince < 0) _notAimSince = now;
                if (_lowerPending && now - _notAimSince >= LowerHold)
                {
                    _lowerPending = false;
                    Plugin.Link.Observe("player_lowered_weapon", new JObject());
                }
            }
        }

        // ------------------------------------------------------------ the view cone (section 6.3/6.4)

        private static void ScanView(GameWorld gw, Player main, float now)
        {
            Vector3 camPos, camFwd;
            var cam = main.CameraPosition;
            if (cam != null) { camPos = cam.position; camFwd = cam.forward; }
            else { camPos = main.Position; camFwd = main.LookDirection; }
            var cands = new List<Candidate>();
            foreach (var kv in People.Mapped())
            {
                var bot = kv.Value;
                if (bot == null) continue;
                bool alive = false;
                var list = gw.AllAlivePlayersList;
                if (list != null) alive = list.Contains(bot);
                if (!alive) continue;
                var to = bot.Position - camPos;
                float dist = to.magnitude;
                if (dist > NoticeM || dist <= 0.001f) continue;
                float ang = Vector3.Angle(camFwd, to);
                if (ang > ConeDeg) continue;
                cands.Add(new Candidate { Id = kv.Key, Dist = dist, Angle = ang });
            }
            cands.Sort(ByRank);
            var nowIn = new HashSet<string>(StringComparer.Ordinal);
            foreach (var c in cands)
            {
                nowIn.Add(c.Id);
                if (InView.Add(c.Id))
                {
                    Seen++;
                    SentDist[c.Id] = c.Dist; SentAt[c.Id] = now;
                    Plugin.Link.Observe("player_seen", new JObject { ["personId"] = c.Id, ["distanceM"] = c.Dist, ["inViewCone"] = true });
                    continue;
                }
                // Already in view. The backend needs a SECOND sample to see an
                // approach at all, but not sixty of them: 0.5 s and 2 m.
                float was, at;
                if (!SentDist.TryGetValue(c.Id, out was)) was = c.Dist;
                if (!SentAt.TryGetValue(c.Id, out at)) at = 0f;
                if (now - at >= SeenRefreshEvery && Mathf.Abs(was - c.Dist) >= SeenRefreshM)
                {
                    SeenRefreshes++;
                    SentDist[c.Id] = c.Dist; SentAt[c.Id] = now;
                    Plugin.Link.Observe("player_seen", new JObject { ["personId"] = c.Id, ["distanceM"] = c.Dist, ["inViewCone"] = true, ["refresh"] = true });
                }
            }
            var gone = new List<string>();
            foreach (var id in InView) if (!nowIn.Contains(id)) gone.Add(id);
            foreach (var id in gone)
            {
                InView.Remove(id); Lost++;
                SentDist.Remove(id); SentAt.Remove(id);
                Plugin.Link.Observe("player_lost", new JObject { ["personId"] = id });
            }
            var next = cands.Count > 0 ? cands[0].Id : null;
            if (next != Addressee) { Addressee = next; if (_aimSince >= 0) _aimSent = false; }
        }

        // ------------------------------------------------------------ movement, damage, death

        private static void SendMoved(Player main)
        {
            Moves++;
            var p = main.Position;
            float yaw = 0f;
            try { yaw = main.Rotation.x; } catch { }
            Plugin.Link.Observe("player_moved", new JObject { ["map"] = Map, ["x"] = p.x, ["y"] = p.y, ["z"] = p.z, ["yaw"] = yaw });
        }

        /// <summary>
        /// Where every BOUND person is, in ONE POST. The backend needs it to
        /// decide who is close enough to hear a line, and it needs it for
        /// people who are NOT in the view cone -- someone shouting at your back
        /// is exactly the case `player_seen` cannot report.
        ///
        /// One request, not one per person: at 40 bound bots the per-person
        /// shape would be 40 fire-and-forget POSTs every 2 s, which is a
        /// different bug wearing this one's clothes.
        /// </summary>
        private static void SendNpcMoved(GameWorld gw)
        {
            var arr = new JArray();
            var alive = gw != null ? gw.AllAlivePlayersList : null;
            foreach (var kv in People.Mapped())
            {
                var bot = kv.Value;
                if (bot == null) continue;
                if (alive != null && !alive.Contains(bot)) continue;
                var p = bot.Position;
                arr.Add(new JObject { ["personId"] = kv.Key, ["x"] = p.x, ["y"] = p.y, ["z"] = p.z });
            }
            if (arr.Count == 0) return;
            NpcMoves++;
            Plugin.Link.Observe("npc_moved", new JObject { ["map"] = Map, ["people"] = arr });
        }

        private static void OnMainDamaged(EBodyPart part, float damage, EFT.Ballistics.DamageInfo info)
        {
            Hits++;
            string by = "";
            try
            {
                var src = info.Player?.iPlayer;
                if (src != null) by = People.PersonFor(src.ProfileId) ?? "";
            }
            catch { }
            float hp = -1f;
            try { hp = _main?.HealthController?.HealthRate ?? -1f; } catch { }
            Plugin.Link.Observe("player_hit", new JObject { ["by"] = by, ["hp"] = hp, ["hpSource"] = "HealthController.HealthRate (semantics unverified)", ["part"] = part.ToString(), ["damage"] = damage });
        }

        private static void OnMainDead(Player player, IPlayer aggressor, EFT.Ballistics.DamageInfo info, EBodyPart part)
        {
            _mainDied = true;
            string by = "";
            try { if (aggressor != null) by = People.PersonFor(aggressor.ProfileId) ?? ""; } catch { }
            Plugin.Link.Observe("player_died", new JObject { ["by"] = by });
        }

        /// <summary>Called by People.Bind: subscribe the bot's death.</summary>
        public static void OnBotBound(string personId, Player bot)
        {
            if (bot == null || !Subscribed.Add(personId)) return;
            try
            {
                bot.OnPlayerDead += (p, aggressor, info, part) =>
                {
                    string by = "";
                    try
                    {
                        if (aggressor != null)
                        {
                            if (_main != null && aggressor.ProfileId == _main.ProfileId) by = "player";
                            else by = People.PersonFor(aggressor.ProfileId) ?? "";
                        }
                    }
                    catch { }
                    Plugin.Link.Observe("npc_died", new JObject { ["personId"] = personId, ["by"] = by });
                };
            }
            catch (Exception ex) { Plugin.Log.LogWarning("basement see: cannot subscribe OnPlayerDead for " + personId + ": " + ex.Message); }
        }
    }
}
