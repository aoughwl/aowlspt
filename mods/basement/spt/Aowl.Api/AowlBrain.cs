using System;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>The synchronous half of a /say answer (the reply text; the spoken segments stream on /events).</summary>
    public sealed class AskReply
    {
        /// <summary>The person asked.</summary>
        public string PersonId;
        /// <summary>The whole reply text.</summary>
        public string Text;
        /// <summary>"builtin", "llm", "cached", ... which tier answered.</summary>
        public string Tier;
        /// <summary>The engine name.</summary>
        public string Engine;
        /// <summary>Milliseconds the backend spent.</summary>
        public int Ms;
        /// <summary>True when the reply was served from the brain cache.</summary>
        public bool Cached;
        /// <summary>True when the reply was streamed sentence by sentence (segments arrived on /events as they were spoken).</summary>
        public bool Streaming;
        /// <summary>The backend's turn id.</summary>
        public long TurnId;
        /// <summary>How many directives the turn put on the stream.</summary>
        public int Directives;
        /// <summary>The encounter state of the person after the turn.</summary>
        public string State;
        /// <summary>Tags the brain attached.</summary>
        public string[] Tags = new string[0];
        /// <summary>The backend's notes.</summary>
        public string[] Notes = new string[0];
        /// <summary>The raw answer.</summary>
        public JObject Raw;
    }

    /// <summary>
    /// One question to one person. The reply's sentences arrive as
    /// <see cref="Sentence"/> events (each with a wav path or "") as the
    /// backend speaks them -- during the request when streaming -- and
    /// <see cref="Answered"/> fires when POST /say returns. All events on the
    /// main thread. Play a sentence with <see cref="AowlSpeech.Say(SpeechRequest)"/>.
    /// </summary>
    public sealed class AskHandle
    {
        /// <summary>The person asked.</summary>
        public readonly string PersonId;
        /// <summary>What was asked.</summary>
        public readonly string Text;
        /// <summary>A sentence of the reply, in order. Fires until the final segment.</summary>
        public event Action<SaySegment> Sentence;
        /// <summary>POST /say answered ok.</summary>
        public event Action<AskReply> Answered;
        /// <summary>POST /say refused or the transport failed; the reason.</summary>
        public event Action<string> Failed;
        /// <summary>The reply once answered (null before / on failure).</summary>
        public AskReply Reply { get; private set; }
        /// <summary>The failure reason (null unless failed).</summary>
        public string Error { get; private set; }
        /// <summary>True once the final segment for this person arrived (or the ask failed).</summary>
        public bool Done { get; private set; }
        private int _segments;

        internal AskHandle(string personId, string text) { PersonId = personId; Text = text; AowlEvents.OnSay += OnSay; }

        private void OnSay(SaySegment s)
        {
            if (Done || !string.Equals(s.PersonId, PersonId, StringComparison.Ordinal)) return;
            // A stale utterance for the same person can still be draining when the ask
            // starts; a fresh utterance begins at segmentIdx 0, so anything before the
            // first 0 we see belongs to the earlier turn.
            if (_segments == 0 && s.SegmentIdx != 0) return;
            _segments++;
            var h = Sentence;
            if (h != null) h(s);
            if (s.Final) Finish();
        }

        private void Finish() { if (Done) return; Done = true; AowlEvents.OnSay -= OnSay; }

        internal void SetReply(AskReply r) { Reply = r; var h = Answered; if (h != null) h(r); if (!r.Streaming && _segments == 0 && (r.Text ?? "").Length == 0) Finish(); }
        internal void SetError(string why) { Error = why; Finish(); var h = Failed; if (h != null) h(why); }
    }

    /// <summary>
    /// The NPC brain: <see cref="Ask"/> (POST /say -- the person's reply,
    /// spoken as <c>say</c> segments on the stream), <see cref="Observe"/>
    /// (POST /observe -- a fact the backend cannot know), and the directive
    /// registry (<see cref="RegisterDirective"/>, the same registry as
    /// <see cref="AowlEvents.Directives"/>).
    /// </summary>
    public static class AowlBrain
    {
        /// <summary>Counters for the status line.</summary>
        public static int Asks, AskFails;

        /// <summary>
        /// Ask <paramref name="personId"/> (a person id from <see cref="AowlWorld"/>)
        /// the line <paramref name="text"/>. Any thread; the request runs in the
        /// background and the handle's events fire on the main thread. The
        /// backend refuses an unknown person and an empty text (the handle's
        /// <see cref="AskHandle.Failed"/> carries its reason).
        /// </summary>
        public static AskHandle Ask(string personId, string text)
        {
            var h = new AskHandle(personId ?? "", text ?? "");
            Asks++;
            if (!AowlBackend.IsReady) { AowlApi.OnMain(() => h.SetError("the backend is not ready (" + AowlBackend.State + ": " + AowlBackend.Note + ")")); AskFails++; return h; }
            var body = new JObject { ["person"] = h.PersonId, ["text"] = h.Text };
            var payload = body.ToString(Newtonsoft.Json.Formatting.None);
            Task.Run(async () =>
            {
                var r = await AowlHttp.PostAsync(AowlHttp.Route("/say"), payload, 180000).ConfigureAwait(false);
                if (!r.Ok)
                {
                    AskFails++;
                    if (AowlApi.Once("say-fail:" + r.Status + ":" + r.Err)) AowlApi.Log.LogWarning("aowl.api brain: POST /say answered " + r.Err + " (HTTP " + r.Status + "). Said once per status and note.");
                    AowlApi.OnMain(() => h.SetError(r.Err));
                    return;
                }
                var j = r.Json;
                var reply = new AskReply
                {
                    PersonId = j.Value<string>("personId") ?? h.PersonId, Text = j.Value<string>("text") ?? "", Tier = j.Value<string>("tier") ?? "",
                    Engine = j.Value<string>("engine") ?? "", Ms = j.Value<int?>("ms") ?? 0, Cached = j.Value<bool?>("cached") ?? false,
                    Streaming = j.Value<bool?>("streaming") ?? false, TurnId = j.Value<long?>("turnId") ?? 0, Directives = j.Value<int?>("directives") ?? 0,
                    State = j.Value<string>("state") ?? "", Tags = Strings(j["tags"]), Notes = Strings(j["notes"]), Raw = j,
                };
                AowlApi.Log.LogInfo("aowl.api brain: /say answered for " + h.PersonId + " -- tier=" + reply.Tier + " engine=" + reply.Engine + " ms=" + reply.Ms +
                    " segments=" + ((j["segments"] as JArray)?.Count ?? 0) + " (the segments play from the event stream, not from this reply)");
                AowlApi.OnMain(() => h.SetReply(reply));
            });
            return h;
        }

        /// <summary>POST /observe {kind, ...fields}: a fact the backend cannot know (player_seen, player_fired, raid_started...). Fire and forget, any thread. Unknown kinds are accepted by the backend and ignored.</summary>
        public static void Observe(string kind, JObject fields) => AowlEvents.Link.Observe(kind, fields);

        /// <summary>POST /ack for a seq you hold outside an <see cref="AowlEvent"/>. Prefer <see cref="AowlEvent.Ack"/>, which guards exactly-once.</summary>
        public static void Ack(long seq, bool ok, string note) => AowlEvents.Link.Ack(seq, ok, note);

        /// <summary>The directive registry; the same as <see cref="AowlEvents.Directives"/>.</summary>
        public static void RegisterDirective(string kind, AowlEvents.Handler handler) => AowlEvents.Directives.Register(kind, handler);

        private static string[] Strings(JToken t)
        {
            var a = t as JArray;
            if (a == null) return new string[0];
            var o = new string[a.Count];
            for (int i = 0; i < a.Count; i++) o[i] = a[i]?.ToString() ?? "";
            return o;
        }
    }
}
