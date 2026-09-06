using System;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// Push-to-talk. The key IS readable here (Mono: UnityEngine.Input.GetKey),
    /// which is the one thing the aowlspt bridge cannot do. Down and up are
    /// POSTed to /speech/ptt {session, state, personId}; the BACKEND records on
    /// this machine and runs progressive STT, so no audio crosses the wire from
    /// this plugin. The addressee is latched at key down (section 6.6) and
    /// named in the down post; `up` is always sent, including on cancel, so a
    /// session never leaks a buffer.
    /// </summary>
    internal static class Hear
    {
        public static bool Holding;
        public static string Session = "";
        public static string LatchedPerson;
        public static string LatchedName;
        public static int Sessions, Downs, Ups, Refused;

        public static void Tick()
        {
            if (!Plugin.Started) return;
            var key = Plugin.PushToTalkKey.Value;
            if (key == KeyCode.None) return;
            if (!Holding && Input.GetKeyDown(key)) Down();
            else if (Holding && (Input.GetKeyUp(key) || !Input.GetKey(key))) Up();
        }

        private static void Down()
        {
            var who = See.Addressee;
            if (who == null && Plugin.TalkNeedsAddressee.Value)
            {
                Refused++;
                Hud.Warn("nobody is listening (no known person alive within " + See.NoticeM + " m and 35 degrees of the camera)", 3f);
                if (Plugin.Once("ptt-nobody")) Plugin.Log.LogInfo("basement hear: talk key pressed with no addressee; no session opened (TalkNeedsAddressee=true). Said once.");
                return;
            }
            Sessions++;
            Downs++;
            Holding = true;
            Session = "spt-" + Guid.NewGuid().ToString("N");
            LatchedPerson = who;
            LatchedName = who != null ? People.NameOf(who) : null;
            Post("down");
        }

        private static void Up()
        {
            if (!Holding) return;
            Holding = false;
            Ups++;
            Post("up");
        }

        private static void Post(string state)
        {
            var body = new JObject { ["session"] = Session, ["state"] = state, ["personId"] = LatchedPerson ?? "" };
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            System.Threading.Tasks.Task.Run(async () =>
            {
                var r = await Http.PostAsync(Http.Route("/speech/ptt"), text, 15000).ConfigureAwait(false);
                if (!r.Ok)
                {
                    if (Plugin.Once("ptt-fail:" + state + ":" + r.Status))
                        Plugin.Log.LogWarning("basement hear: POST /speech/ptt " + state + " answered " + r.Err + " (HTTP " + r.Status + "). Said once per state and status.");
                    Plugin.OnMain(() => Hud.Warn("talk: " + r.Err, 4f));
                    return;
                }
                var note = r.Json.Value<string>("note") ?? "";
                if (state == "up")
                {
                    var fin = r.Json.Value<string>("final") ?? "";
                    Plugin.OnMain(() => { if (fin.Length == 0) Hud.Warn("not transcribed" + (note.Length > 0 ? ": " + note : "")); });
                }
                Plugin.Log.LogInfo("basement hear: ptt " + state + " ok " + note);
            });
        }
    }
}
