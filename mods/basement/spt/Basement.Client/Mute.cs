using System;
using System.Reflection;
using HarmonyLib;

namespace Basement.Client
{
    /// <summary>
    /// Mutes the game's own bot chatter so the only voices in the world are the
    /// backend's people. The user's instruction (2026-09-07): "completely
    /// disable the vanilla NPC/bot voice lines entirely".
    ///
    /// Chokepoint: `BotTalk.Say(EPhraseTrigger type, bool sayImmediately,
    /// Nullable&lt;ETagStatus&gt; additionalMask)` -- every TrySay / SayFromQuery /
    /// SayAndDelay overload funnels into it (VERIFIED against
    /// Assembly-CSharp 4.1.5 with MemberCheck: `BotTalk : BotData` in the global
    /// namespace, one `Say` with those three parameters). A Harmony prefix that
    /// returns false skips the original, so no phrase is queued and nothing is
    /// played. Player VOIP and the player's own voice lines are a different
    /// class and are untouched.
    ///
    /// Resolved by NAME through AccessTools so a rename in a later build gives a
    /// logged refusal ("type BotTalk not found"), never a compile-time bind to
    /// a wrong member.
    /// </summary>
    internal static class Mute
    {
        private static Harmony _harmony;
        public static string Note = "not installed";
        public static long Suppressed;

        public static void Install()
        {
            if (!Plugin.MuteVanillaVoice.Value)
            {
                Note = "off (MuteVanillaVoice=false)";
                Plugin.Log.LogInfo("basement mute: " + Note + " -- vanilla bot voice lines play as usual.");
                return;
            }
            try
            {
                var t = AccessTools.TypeByName("BotTalk");
                if (t == null) { Note = "type BotTalk not found in this build; vanilla voices NOT muted"; Plugin.Log.LogWarning("basement mute: " + Note); return; }
                MethodInfo say = null;
                foreach (var m in t.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
                    if (m.Name == "Say" && m.GetParameters().Length == 3) { say = m; break; }
                if (say == null) { Note = "BotTalk.Say(3 args) not found; vanilla voices NOT muted"; Plugin.Log.LogWarning("basement mute: " + Note); return; }
                _harmony = new Harmony("aowl.basement.mute");
                _harmony.Patch(say, prefix: new HarmonyMethod(typeof(Mute), nameof(SayPrefix)));
                Note = "BotTalk.Say prefixed; every vanilla bot phrase is dropped before it is queued";
                Plugin.Log.LogInfo("basement mute: " + Note);
            }
            catch (Exception ex)
            {
                Note = "Harmony install threw " + ex.Message;
                Plugin.Log.LogError("basement mute: " + Note);
            }
        }

        // Returning false skips BotTalk.Say entirely. Counted so /status-style
        // reporting can show the mute is actually firing, not merely installed.
        public static bool SayPrefix()
        {
            Suppressed++;
            return false;
        }
    }
}
