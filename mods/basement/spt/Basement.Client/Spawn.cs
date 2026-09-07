using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading.Tasks;
using Aowl.Api;
using EFT;
using EFT.UI;
using EFT.UI.Matchmaker;
using HarmonyLib;
using JsonType;
using Newtonsoft.Json.Linq;

namespace Basement.Client
{
    /// <summary>
    /// Always in raid. On the main menu (a Harmony postfix on
    /// MenuScreen.Show(Profile, MatchmakerPlayersController, ESessionMode) --
    /// verified in Assembly-CSharp 4.1.5) GET /spawn and log the map.
    ///
    /// ACTUALLY starting the raid is behind [Raid] AutoRaidStart (default OFF).
    /// The path, every member of which was verified offline with Mono.Cecil
    /// against D:\SPT415\EscapeFromTarkov_Data\Managed\Assembly-CSharp.dll
    /// (2026-09-06) but NEVER yet executed in a live client:
    ///
    ///   TarkovApplication.Exist(out app)                       static
    ///   app._raidSettings : RaidSettings                        field (null until the matchmaker built one -> refused)
    ///   app.Session.LocationSettings.locations : Dictionary<string, LocationSettings.Location>
    ///   RaidSettings.SelectedLocation / Side / RaidMode / IsPveOffline
    ///   app.OnReadyToStartMatchingAsync() : Task                what the Ready button ends in; it reads
    ///                                                           _raidSettings, StoreProfile()s the menu
    ///                                                           operation, then LocalGameMatching(...) when
    ///                                                           RaidSettings.Local (== RaidMode.Local)
    ///
    /// What it SKIPS, said plainly: the offline-raid screen, where SPT's
    /// SetPreRaidSettingsScreenDefaultsPatch fills BotSettings / WavesSettings.
    /// Whatever _raidSettings holds at that moment is what the raid gets.
    /// </summary>
    internal static class Spawn
    {
        public static bool MenuSeen;
        public static string LastMap = "";
        public static string LastReason = "";
        public static string LastWhy = "";
        public static int Requests, Arms, Refusals;
        private static bool _armed;          // a raid was requested; wait until See saw it and then saw it end
        private static bool _requestPending;
        private static bool _menuDirty;
        private static float _lastAsk = -1e9f;
        private static Harmony _harmony;

        public static void Install()
        {
            try
            {
                _harmony = new Harmony("aowl.basement");
                var show = AccessTools.Method(typeof(MenuScreen), "Show", new[] { typeof(Profile), typeof(MatchmakerPlayersController), typeof(ESessionMode) });
                if (show == null) { Plugin.Log.LogError("basement spawn: MenuScreen.Show(Profile, MatchmakerPlayersController, ESessionMode) not found on this build; the menu hook is OFF."); }
                else _harmony.Patch(show, postfix: new HarmonyMethod(typeof(Spawn), nameof(MenuShownPostfix)));

                var result = AccessTools.Method(typeof(TarkovApplication), "ShowSessionResult");
                if (result == null) { Plugin.Log.LogWarning("basement spawn: TarkovApplication.ShowSessionResult not found; raid_ended will not know extract from death."); }
                else _harmony.Patch(result, prefix: new HarmonyMethod(typeof(Spawn), nameof(SessionResultPrefix)));
            }
            catch (Exception ex)
            {
                Plugin.Log.LogError("basement spawn: Harmony install threw " + ex);
            }
        }

        // Harmony targets. Names of the parameters must match the original's.
        private static void MenuShownPostfix() { MenuSeen = true; _menuDirty = true; }
        private static void SessionResultPrefix(ExitStatus exitStatus) { See.OnExitStatus(exitStatus.ToString()); }

        /// <summary>Main thread, every frame.</summary>
        public static void Tick()
        {
            if (!Plugin.Started || !Plugin.SpawnOnMenu.Value) return;
            if (!_menuDirty || _requestPending) return;
            if (_armed)
            {
                // Latched until the raid we asked for has been seen AND left.
                if (See.RaidsEnded > _armedAtEnds) _armed = false;
                else return;
            }
            if (UnityEngine.Time.realtimeSinceStartup - _lastAsk < 5f) return;
            _lastAsk = UnityEngine.Time.realtimeSinceStartup;
            _menuDirty = false;
            _requestPending = true;
            Requests++;
            Task.Run(async () =>
            {
                var r = await AowlWorld.SpawnAsync().ConfigureAwait(false);
                Plugin.OnMain(() => OnSpawnReply(r));
            });
        }

        private static int _armedAtEnds;

        private static void OnSpawnReply(Result<SpawnPlace> r)
        {
            _requestPending = false;
            if (!r.Ok)
            {
                Refusals++; LastWhy = r.Error;
                if (Plugin.Once("spawn-http:" + r.Error)) Plugin.Log.LogWarning("basement spawn: " + LastWhy);
                return;
            }
            var sp = r.Value;
            var map = sp.Map;
            if (map.Length == 0)
            {
                Refusals++; LastWhy = sp.Err ?? "the backend answered ok:false with no map";
                if (Plugin.Once("spawn-notok:" + LastWhy)) Plugin.Log.LogWarning("basement spawn: the backend declined to place the player -- " + LastWhy);
                return;
            }
            LastMap = map;
            LastReason = sp.Reason;
            Plugin.Log.LogInfo("basement spawn: the world wants the player on map \"" + map + "\" at " + sp.X + "," + sp.Y + "," + sp.Z + " (" + LastReason + ")");
            Hud.Note("basement: next raid -> " + map + " (" + LastReason + ")", 8f);
            if (!Plugin.AutoRaidStart.Value)
            {
                if (Plugin.Once("spawn-off")) Plugin.Log.LogInfo("basement spawn: AutoRaidStart=false, so the raid is NOT started from code; the map is logged only.");
                return;
            }
            string why;
            if (StartRaid(map, out why)) { Arms++; _armed = true; _armedAtEnds = See.RaidsEnded; Plugin.Log.LogInfo("basement spawn: raid start requested for " + map); }
            else { Refusals++; LastWhy = why; Plugin.Log.LogWarning("basement spawn: could not start the raid -- " + why); Hud.Warn("basement: raid not started: " + why, 8f); }
        }

        /// <summary>The player.spawn directive. Acked ok only when the raid was actually requested.</summary>
        public static void OnDirective(long seq, JObject data)
        {
            var map = data.Value<string>("map") ?? "";
            if (!Plugin.AutoRaidStart.Value)
            {
                Plugin.Link.Ack(seq, false, "AutoRaidStart is off in aowl.basement.cfg; the map (" + map + ") was logged, no raid started");
                return;
            }
            if (See.InRaid) { Plugin.Link.Ack(seq, false, "already in a raid"); return; }
            if (!MenuSeen) { Plugin.Link.Ack(seq, false, "the main menu has not been shown yet"); return; }
            string why;
            if (StartRaid(map, out why)) { Arms++; _armed = true; _armedAtEnds = See.RaidsEnded; Plugin.Link.Ack(seq, true, "raid start requested for " + map); }
            else Plugin.Link.Ack(seq, false, why);
        }

        private static bool StartRaid(string map, out string why)
        {
            why = null;
            TarkovApplication app = null;
            try
            {
                if (!TarkovApplication.Exist(out app) || app == null) { why = "TarkovApplication does not exist yet"; return false; }
                var rsField = AccessTools.Field(typeof(TarkovApplication), "_raidSettings");
                var rs = rsField?.GetValue(app) as RaidSettings;
                if (rs == null) { why = "TarkovApplication._raidSettings is null: the matchmaker has not built one on this menu yet (refused rather than constructing one blind)"; return false; }

                var sessionProp = AccessTools.Property(typeof(TarkovApplication), "Session") ?? AccessTools.Property(typeof(TarkovApplication).BaseType, "Session");
                var session = sessionProp?.GetValue(app) as IEftSession;
                var locs = session?.LocationSettings?.locations;
                if (locs == null) { why = "Session.LocationSettings.locations is null"; return false; }
                LocationSettings.Location loc = null;
                foreach (var kv in locs)
                {
                    if (kv.Value == null) continue;
                    if (string.Equals(kv.Key, map, StringComparison.OrdinalIgnoreCase) || string.Equals(kv.Value.Id, map, StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(kv.Value.Name, map, StringComparison.OrdinalIgnoreCase)) { loc = kv.Value; break; }
                }
                if (loc == null)
                {
                    var ids = new List<string>();
                    foreach (var kv in locs) ids.Add(kv.Key);
                    why = "no location matches \"" + map + "\" by key, Id or Name; known: " + string.Join(", ", ids);
                    return false;
                }
                rs.SelectedLocation = loc;
                rs.Side = ESideType.Pmc;
                rs.RaidMode = ERaidMode.Local;
                rs.IsPveOffline = true;
                var ready = AccessTools.Method(typeof(TarkovApplication), "OnReadyToStartMatchingAsync");
                if (ready == null) { why = "TarkovApplication.OnReadyToStartMatchingAsync not found"; return false; }
                var task = ready.Invoke(app, null) as Task;
                if (task != null) task.ContinueWith(t =>
                {
                    if (t.IsFaulted) Plugin.Log.LogError("basement spawn: OnReadyToStartMatchingAsync faulted: " + t.Exception?.GetBaseException());
                });
                return true;
            }
            catch (Exception ex)
            {
                why = "StartRaid threw " + ex.GetType().Name + ": " + ex.Message;
                return false;
            }
        }
    }
}
