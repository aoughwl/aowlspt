using System.Threading.Tasks;
using Aowl.Api;
using BepInEx;
using UnityEngine;

namespace HelloAowl
{
    /// <summary>
    /// The smallest useful Aowl API consumer. F9: ask the nearest backend
    /// person "what is your name" and play the reply through AowlSpeech.
    /// Also handles the `hud.note` directive kind. Everything it touches is
    /// public API; it never talks HTTP itself.
    /// </summary>
    [BepInPlugin("example.helloaowl", "Hello Aowl", "0.1.0")]
    [BepInDependency(AowlApi.Guid, BepInDependency.DependencyFlags.HardDependency)]
    public sealed class Plugin : BaseUnityPlugin
    {
        private bool _busy;

        private void Awake()
        {
            // Any plugin can own an event kind. Several may share one; a directive's first ack wins.
            AowlEvents.Directives.Register("hud.note", e => Logger.LogInfo("HUD " + e.Str("severity", "info") + ": " + e.Str("text")));
            AowlBackend.StateChanged += s => Logger.LogInfo("aowl backend is " + s + " (" + AowlBackend.Note + "); backend " + AowlBackend.BackendVersion + " " + AowlBackend.Compatibility);
            Logger.LogInfo("HelloAowl loaded against Aowl API " + AowlApi.Version + "; press F9 near a person.");
        }

        private void Update()
        {
            if (_busy || !Input.GetKeyDown(KeyCode.F9)) return;
            if (!AowlBackend.IsReady) { Logger.LogWarning("aowl backend not ready: " + AowlBackend.State + " -- " + AowlBackend.Note); return; }
            var cam = Camera.main;
            var here = cam != null ? cam.transform.position : Vector3.zero;
            _busy = true;
            Task.Run(async () =>
            {
                // World queries are typed and never throw; a refusal is the Error string.
                var people = await AowlWorld.PeopleAsync();
                AowlApi.OnMain(() =>
                {
                    _busy = false;
                    if (!people.Ok) { Logger.LogWarning("no people: " + people.Error); return; }
                    var who = AowlWorld.Nearest(people.Value, here.x, here.y, here.z);
                    if (who == null) { Logger.LogWarning("the world has nobody alive to ask"); return; }
                    Logger.LogInfo("asking " + who.Name + " (" + who.Id + ", " + who.Role + " of " + who.Faction + ")...");
                    var ask = AowlBrain.Ask(who.Id, "what is your name");
                    // Sentences stream in as the backend speaks them; each carries its wav (or "" when TTS is off).
                    ask.Sentence += seg =>
                    {
                        Logger.LogInfo(who.Name + ": " + seg.Text + (seg.Wav.Length == 0 ? "  [no wav: " + seg.TtsNote + "]" : ""));
                        var h = AowlSpeech.Say(new SpeechRequest { Text = seg.Text, Wav = seg.Wav, PersonId = who.Id, Position = here + Vector3.forward * 2f });
                        h.Failed += (hh, why) => Logger.LogWarning("could not play: " + why);
                    };
                    ask.Answered += r => Logger.LogInfo("reply (" + r.Tier + "/" + r.Engine + ", " + r.Ms + " ms): " + r.Text);
                    ask.Failed += why => Logger.LogWarning("ask refused: " + why);
                });
            });
        }
    }
}
