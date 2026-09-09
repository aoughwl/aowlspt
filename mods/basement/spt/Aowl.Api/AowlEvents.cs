using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>
    /// One event off the backend stream (GET /events), as handed to a handler.
    /// A directive is an event whose <see cref="WantsAck"/> is true: the
    /// backend waits for <see cref="Ack"/> and journals <c>directive.dropped</c>
    /// after its ttl if none arrives. Acking is guarded to exactly once.
    /// </summary>
    public sealed class AowlEvent
    {
        /// <summary>The stream seq (monotonic; the ack key).</summary>
        public long Seq;
        /// <summary>The kind: say, heard.partial, heard.final, hud.note, npc.goto, player.spawn, ...</summary>
        public string Kind;
        /// <summary>The event's data object. The event-level ack/ttlMs are folded in as data["ack"], data["ttlMs"].</summary>
        public JObject Data;
        /// <summary>True when the backend expects a POST /ack for this seq.</summary>
        public bool WantsAck;
        /// <summary>The ttl the backend gives the ack (ms), 0 when unknown.</summary>
        public long TtlMs;
        private int _acked;
        private readonly Link _link;

        internal AowlEvent(Link link, long seq, string kind, JObject data, bool wantsAck)
        {
            _link = link; Seq = seq; Kind = kind; Data = data; WantsAck = wantsAck;
            TtlMs = data.Value<long?>("ttlMs") ?? 0;
        }

        /// <summary>True once <see cref="Ack"/> has been called.</summary>
        public bool Acked => _acked != 0;

        /// <summary>
        /// POST /ack {seq, ok, note}. Exactly once: a second call is ignored and
        /// logged. <c>ok:false</c> with a reason is a first-class answer ("no
        /// navmesh at that point"); never leave a directive unacked. A passive
        /// event (<see cref="WantsAck"/> false) may be acked too; the backend
        /// answers "not pending", which the link logs and nothing else.
        /// </summary>
        public void Ack(bool ok, string note)
        {
            if (System.Threading.Interlocked.Exchange(ref _acked, 1) != 0)
            {
                if (AowlApi.Once("double-ack:" + Kind)) AowlApi.Log.LogWarning("aowl.api: seq " + Seq + " (" + Kind + ") acked twice; the second ack was dropped. Said once per kind.");
                return;
            }
            _link.Ack(Seq, ok, note);
        }

        /// <summary>data[name] as a string, or <paramref name="dflt"/>.</summary>
        public string Str(string name, string dflt = "") => Data.Value<string>(name) ?? dflt;
    }

    /// <summary>A <c>say</c> event: one sentence of one person's reply, with its wav (or "" when TTS is off/failed).</summary>
    public sealed class SaySegment
    {
        /// <summary>The stream seq of this segment (play in seq order).</summary>
        public long Seq;
        /// <summary>The speaking person's id ("" for nobody in particular).</summary>
        public string PersonId;
        /// <summary>Index within the utterance; 0 begins a new utterance and supersedes what is queued.</summary>
        public int SegmentIdx;
        /// <summary>Absolute wav path on the backend machine, or "" -- then the text IS the line; never substitute a beep.</summary>
        public string Wav;
        /// <summary>The sentence.</summary>
        public string Text;
        /// <summary>True on the last segment of the utterance. Do NOT wait for it before playing earlier ones.</summary>
        public bool Final;
        /// <summary>"brain", "bark", ... where the line came from.</summary>
        public string Source;
        /// <summary>The voice name the backend resolved for the person.</summary>
        public string Voice;
        /// <summary>The backend's TTS engine name for this line.</summary>
        public string Engine;
        /// <summary>The backend's note on synthesis ("" when it went well).</summary>
        public string TtsNote;
        /// <summary>True when the backend served the wav from its cache.</summary>
        public bool CachedWav;
        /// <summary>The whole event, for fields not lifted here (voiceSpec...).</summary>
        public AowlEvent Event;

        /// <summary>Read a <c>say</c> event into this shape (for a handler registered on "say").</summary>
        public static SaySegment From(AowlEvent e)
        {
            var d = e.Data;
            return new SaySegment
            {
                Seq = e.Seq, PersonId = d.Value<string>("personId") ?? "", SegmentIdx = d.Value<int?>("segmentIdx") ?? 0,
                Wav = d.Value<string>("wav") ?? "", Text = d.Value<string>("text") ?? "", Final = d.Value<bool?>("final") ?? false,
                Source = d.Value<string>("source") ?? "", Voice = d.Value<string>("voice") ?? "", Engine = d.Value<string>("engine") ?? d.Value<string>("tts") ?? "",
                TtsNote = d.Value<string>("ttsNote") ?? "", CachedWav = d.Value<bool?>("cachedWav") ?? false, Event = e,
            };
        }
    }

    /// <summary>A <c>heard.partial</c> / <c>heard.final</c> event: what the backend transcribed of the player.</summary>
    public sealed class HeardEvent
    {
        /// <summary>The transcript. On a final, "" means NOT TRANSCRIBED, never "the player said nothing"; show <see cref="Note"/>.</summary>
        public string Text;
        /// <summary>True for heard.final.</summary>
        public bool Final;
        /// <summary>The backend's note (e.g. the missing whisper path).</summary>
        public string Note;
        /// <summary>"ptt" when the backend recorder produced it; "" for the chunk path.</summary>
        public string Source;
        /// <summary>The whole event.</summary>
        public AowlEvent Event;
    }

    /// <summary>
    /// The event stream and the directive registry. Handlers run on the Unity
    /// MAIN thread, in stream order, one event at a time.
    ///
    /// <c>Directives.Register("npc.goto", e =&gt; { ...; e.Ack(true, "accepted"); })</c>
    /// lets ANY plugin handle a kind. Several handlers may share a kind (all
    /// run, in registration order); for a directive the FIRST ack wins and the
    /// rest are dropped with a log line. A directive with no handler is acked
    /// <c>ok:false "unsupported kind"</c> by the API itself, never ignored. A
    /// handler that throws acks <c>ok:false</c> with the exception.
    ///
    /// Register during Awake: events dispatched before a handler exists for
    /// their kind are handled by the fallback above, not queued.
    /// </summary>
    public static class AowlEvents
    {
        /// <summary>The stream loop (counters, cursor, Ack/Observe).</summary>
        public static readonly Link Link = new Link();

        /// <summary>Handler signature: the event, on the main thread.</summary>
        public delegate void Handler(AowlEvent e);

        /// <summary>The registry of directive/event handlers by kind.</summary>
        public static class Directives
        {
            private static readonly Dictionary<string, List<Handler>> ByKind = new Dictionary<string, List<Handler>>(StringComparer.Ordinal);
            private static readonly object Gate = new object();

            /// <summary>Register <paramref name="h"/> for <paramref name="kind"/> (exact match, e.g. "hud.note"). Any thread.</summary>
            public static void Register(string kind, Handler h)
            {
                if (string.IsNullOrEmpty(kind) || h == null) return;
                lock (Gate)
                {
                    if (!ByKind.TryGetValue(kind, out var list)) { list = new List<Handler>(); ByKind[kind] = list; }
                    list.Add(h);
                }
            }

            /// <summary>Remove one registration. Returns true when it was present.</summary>
            public static bool Unregister(string kind, Handler h)
            {
                lock (Gate) return kind != null && ByKind.TryGetValue(kind, out var list) && list.Remove(h);
            }

            /// <summary>The kinds with at least one handler.</summary>
            public static string[] Kinds { get { lock (Gate) { var a = new string[ByKind.Count]; ByKind.Keys.CopyTo(a, 0); return a; } } }
            /// <summary>How many kinds have a handler.</summary>
            public static int Count { get { lock (Gate) return ByKind.Count; } }
            /// <summary>True when <paramref name="kind"/> has a handler.</summary>
            public static bool Handles(string kind) { lock (Gate) return kind != null && ByKind.ContainsKey(kind); }

            internal static Handler[] For(string kind)
            {
                lock (Gate) return ByKind.TryGetValue(kind, out var list) ? list.ToArray() : null;
            }
        }

        /// <summary>Every event, before kind-specific handlers. Main thread. Do not ack from here unless you mean to own the directive.</summary>
        public static event Action<AowlEvent> OnEvent;
        /// <summary>Every <c>say</c> segment, typed. Main thread.</summary>
        public static event Action<SaySegment> OnSay;
        /// <summary><c>heard.partial</c> and <c>heard.final</c>, typed. Main thread.</summary>
        public static event Action<HeardEvent> OnHeard;
        /// <summary><c>hud.note</c>: (text, severity "info"|"warn"). Main thread.</summary>
        public static event Action<string, string> OnHudNote;
        /// <summary>The link resynced after a hole or a backend restart -- re-read /world/people. LINK thread (not main); reason is "hole" or "backend restart".</summary>
        public static event Action<string> OnResync;
        /// <summary>The backend DROPPED a directive (no ack within ttl): (seq, kind, reason). Main thread. That is a bug in a client.</summary>
        public static event Action<long, string, string> OnDirectiveDropped;

        internal static void RaiseResync(string reason)
        {
            var h = OnResync;
            if (h == null) return;
            try { h(reason); } catch (Exception ex) { AowlApi.Log.LogWarning("aowl.api: an OnResync subscriber threw " + ex.Message); }
        }

        /// <summary>The kinds the backend sends without an ack when the event carries no ack flag at all.</summary>
        private static bool PassiveKind(string kind) =>
            kind == "say" || kind.StartsWith("heard.") || kind == "hud.note" ||
            kind == "world.saved" || kind.StartsWith("directive.") || kind.StartsWith("quest.");

        // ------------------------------------------------------------ dispatch (main thread)

        internal static void Dispatch(Link link, long seq, string kind, JObject data)
        {
            // MEASURED 2026-09-07: the backend's event JSON carried no `ack` field at
            // all, so every directive was silently "passive" here and dropped after
            // ttl on the other side. Until the backend writes it, a directive kind
            // (anything not in the passive set) wants an ack.
            // The flag is a SIBLING of `data` at the event level (backend commit
            // a00de63 writes {seq, atMs, kind, ack, ttlMs, data}); the link folds it in.
            bool? ackField = data.Value<bool?>("ack");
            bool wantsAck = ackField ?? !PassiveKind(kind);
            if (wantsAck) link.Directives++;
            var e = new AowlEvent(link, seq, kind, data, wantsAck);

            var any = OnEvent;
            if (any != null) { try { any(e); } catch (Exception ex) { AowlApi.Log.LogError("aowl.api: an OnEvent subscriber threw on " + kind + ": " + ex); } }

            // Typed convenience events, before the kind handlers.
            try
            {
                switch (kind)
                {
                    case "say": { var h = OnSay; if (h != null) h(SaySegment.From(e)); break; }
                    case "heard.partial":
                    case "heard.final":
                    {
                        var h = OnHeard;
                        if (h != null) h(new HeardEvent { Text = e.Str("text"), Final = kind == "heard.final", Note = e.Str("note"), Source = e.Str("source"), Event = e });
                        break;
                    }
                    case "hud.note": { var h = OnHudNote; if (h != null) h(e.Str("text"), e.Str("severity", "info")); break; }
                    case "directive.acked": return;   // echo of our own ack
                    case "directive.dropped":
                    {
                        AowlApi.Log.LogWarning("aowl.api link: the backend DROPPED directive seq " + data.Value<long?>("seq") + " (" +
                            data.Value<string>("kind") + ") -- " + (data.Value<string>("reason") ?? "no reason") +
                            ". That is a bug in a client: an unacked directive means the world proceeded as though the thing did not happen.");
                        var h = OnDirectiveDropped;
                        if (h != null) h(data.Value<long?>("seq") ?? 0, data.Value<string>("kind") ?? "", data.Value<string>("reason") ?? "");
                        break;
                    }
                }
            }
            catch (Exception ex) { AowlApi.Log.LogError("aowl.api: a typed-event subscriber threw on " + kind + ": " + ex); }

            var handlers = Directives.For(kind);
            if (handlers != null)
            {
                foreach (var h in handlers)
                {
                    try { h(e); }
                    catch (Exception ex)
                    {
                        AowlApi.Log.LogError("aowl.api: handler for `" + kind + "` (seq " + seq + ") threw " + ex);
                        if (wantsAck && !e.Acked) e.Ack(false, "handler threw " + ex.GetType().Name + ": " + ex.Message);
                    }
                }
                return;
            }
            if (!wantsAck)
            {
                if (AowlApi.Once("unknown-passive:" + kind))
                    AowlApi.Log.LogInfo("aowl.api link: event kind `" + kind + "` has no handler and carries no ack. Ignored, said once.");
                return;
            }
            link.Unsupported++;
            if (AowlApi.Once("unsupported:" + kind))
                AowlApi.Log.LogWarning("aowl.api link: no plugin registered a handler for directive kind `" + kind + "` -- ACKED ok:false \"unsupported kind\", never ignored. Said once per kind.");
            e.Ack(false, "unsupported kind: no plugin registered a handler for `" + kind + "` (AowlEvents.Directives.Register)");
        }
    }
}
