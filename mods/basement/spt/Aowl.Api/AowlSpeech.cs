using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Aowl.Api
{
    /// <summary>What to play. Exactly one of Wav / Clip must be set for audio; text alone is a subtitle-only line.</summary>
    public sealed class SpeechRequest
    {
        /// <summary>The line (for subtitles and the log). May be "".</summary>
        public string Text = "";
        /// <summary>Absolute path of a 16-bit PCM RIFF wav on this machine (the backend's `say` segments carry one), or "".</summary>
        public string Wav = "";
        /// <summary>A ready AudioClip instead of a wav path.</summary>
        public AudioClip Clip;
        /// <summary>Who speaks (for the subtitle event and the per-speaker channel). "" = nobody in particular.</summary>
        public string PersonId = "";
        /// <summary>Play spatially from this transform (a bot's GameObject). Wins over Position.</summary>
        public Transform At;
        /// <summary>Play spatially from a fixed world position.</summary>
        public Vector3? Position;
        /// <summary>Spatial max distance, metres (linear rolloff).</summary>
        public float MaxDistance = 40f;
        /// <summary>
        /// A backend voice name (e.g. a person's <see cref="PersonInfo.Voice"/>). Recorded on the handle only: the backend
        /// (0.1.0) exposes NO text-only TTS route -- the only synthesis is a person's reply via <see cref="AowlBrain.Ask"/>,
        /// whose segments arrive with their wav already made. A request with a VoiceSpec but neither Wav nor Clip is
        /// therefore refused (<see cref="SpeechHandle.Failed"/>), never silently shown as a subtitle.
        /// </summary>
        public string VoiceSpec = "";
    }

    /// <summary>One playing (or refused) line. Events on the main thread.</summary>
    public sealed class SpeechHandle
    {
        /// <summary>The request.</summary>
        public readonly SpeechRequest Request;
        /// <summary>Audio began (or, for a subtitle-only line, the line was announced).</summary>
        public event Action<SpeechHandle> Started;
        /// <summary>Audio ended (AudioSource.isPlaying went false) or the subtitle line was announced.</summary>
        public event Action<SpeechHandle> Finished;
        /// <summary>The wav could not be played; the reason. The text is still the line -- show it.</summary>
        public event Action<SpeechHandle, string> Failed;
        /// <summary>The source playing it (null for subtitle-only / failed).</summary>
        public AudioSource Source { get; internal set; }
        /// <summary>The clip length in seconds (0 when none).</summary>
        public float Seconds { get; internal set; }
        /// <summary>True while audio plays.</summary>
        public bool IsPlaying => Source != null && Source.isPlaying;
        /// <summary>The failure reason (null unless failed).</summary>
        public string Error { get; internal set; }
        /// <summary>True once Finished or Failed fired.</summary>
        public bool Done { get; internal set; }
        /// <summary>True when the line had no audio and was a subtitle only.</summary>
        public bool SubtitleOnly { get; internal set; }
        internal float StartedAt;
        internal SpeechHandle(SpeechRequest r) { Request = r; }
        internal void RaiseStarted() { var h = Started; if (h != null) h(this); }
        internal void RaiseFinished() { if (Done) return; Done = true; var h = Finished; if (h != null) h(this); }
        internal void RaiseFailed(string why) { if (Done) return; Done = true; Error = why; var h = Failed; if (h != null) h(this, why); }
        /// <summary>Stop the audio now (Finished fires on the next tick).</summary>
        public void Stop() { try { if (Source != null && Source.isPlaying) Source.Stop(); } catch { } }
    }

    /// <summary>The transcript of a finished <see cref="ListenSession"/>.</summary>
    public sealed class ListenResult
    {
        /// <summary>The transcript; "" means NOT TRANSCRIBED (see Note), never "the player said nothing".</summary>
        public string Text;
        /// <summary>The backend's note (e.g. the missing whisper path).</summary>
        public string Note;
        /// <summary>Null when the backend did not hand the transcript to the brain (then Ask it yourself); "" when it tried and nobody was addressed; else the person id it asked.</summary>
        public string SpokeTo;
        /// <summary>The brain's reply text when SpokeTo names a person (its segments arrive on the stream).</summary>
        public string Reply;
        /// <summary>The backend's explanation of what it did with the transcript.</summary>
        public string SayNote;
        /// <summary>Key-up (Finish) to transcript, milliseconds.</summary>
        public long ElapsedMs;
        /// <summary>The raw final chunk answer.</summary>
        public JObject Raw;
    }

    /// <summary>
    /// One push-to-talk utterance streamed to POST /speech/chunk: push PCM as
    /// it is captured, <see cref="Finish"/> on release. The addressee travels
    /// in the first chunk (CLIENT-CONTRACT 6.7). Chunks go through ONE sender
    /// thread in order; chunks queued behind a slow request are merged so seq
    /// stays dense and no audio is dropped. Every session MUST be finished,
    /// including on cancel, or the backend leaks a buffer.
    /// </summary>
    public sealed class ListenSession
    {
        /// <summary>The session id sent to the backend (unique per utterance).</summary>
        public readonly string Id;
        /// <summary>The person the player is talking to ("" = nobody; the backend then falls back to its captive).</summary>
        public readonly string PersonId;
        /// <summary>A partial transcript (a PREVIEW: it changes and is never fed to the brain). Main thread.</summary>
        public event Action<string> Partial;
        /// <summary>The final transcript and what the backend did with it. Main thread.</summary>
        public event Action<ListenResult> Final;
        /// <summary>A chunk was refused or the transport failed: (reason, wasFinal). Main thread. Said per chunk.</summary>
        public event Action<string, bool> Failed;
        /// <summary>Chunks pushed so far (the next seq).</summary>
        public int Seq { get; private set; }
        /// <summary>True once Finish was called.</summary>
        public bool Finished { get; private set; }
        /// <summary>The result once Final fired.</summary>
        public ListenResult Result { get; private set; }
        private Resampler _rs;
        private long _upAtMs;

        internal ListenSession(string personId, string id) { PersonId = personId ?? ""; Id = id; }

        /// <summary>Push 16 kHz mono PCM16 bytes (already in the wire format). Main or any thread.</summary>
        public void Push(byte[] pcm16k, bool final = false)
        {
            if (Finished) { if (AowlApi.Once("push-after-finish")) AowlApi.Log.LogWarning("aowl.api listen: a chunk was pushed after Finish() on session " + Id + "; dropped. Said once."); return; }
            if (final) { Finished = true; _upAtMs = AowlApi.NowMs; }
            var c = new AowlSpeech.Chunk { Session = this, Seq = Seq++, Pcm = pcm16k ?? new byte[0], Final = final, UpAtMs = final ? _upAtMs : 0 };
            AowlSpeech.EnqueueChunk(c);
        }

        /// <summary>Push float samples at <paramref name="srcRate"/> Hz (mono); they are resampled to 16 kHz PCM16 with the carry kept across pushes.</summary>
        public void Push(float[] samples, int count, int srcRate, bool final = false)
        {
            if (_rs == null || _rs.SrcRate != srcRate) _rs = new Resampler(srcRate, 16000);
            Push(_rs.Push(samples, count), final);
        }

        /// <summary>Send the final (empty) chunk. Always call it -- also on cancel.</summary>
        public void Finish() { if (!Finished) Push(new byte[0], true); }

        internal void RaisePartial(string t) { var h = Partial; if (h != null) h(t); }
        internal void RaiseFinal(ListenResult r) { Result = r; var h = Final; if (h != null) h(r); }
        internal void RaiseFailed(string why, bool final) { var h = Failed; if (h != null) h(why, final); }
    }

    /// <summary>
    /// Speech out and speech in.
    ///
    /// OUT: <see cref="Say(SpeechRequest)"/> plays a wav (the path a `say`
    /// segment carries) at a transform, a position, or 2-D, through a cached
    /// AudioClip (<see cref="LoadClip"/>, keyed by path + size + mtime).
    /// AudioSource.isPlaying IS a completion signal on Mono, so
    /// <see cref="SpeechHandle.Finished"/> is exact.
    ///
    /// IN: <see cref="Listen"/> opens a push-to-talk session streaming to
    /// /speech/chunk; <see cref="PushToTalk"/> is the backend-recorder
    /// fallback (/speech/ptt) for when the client cannot capture.
    /// </summary>
    public static class AowlSpeech
    {
        /// <summary>Counters for the status line.</summary>
        public static int Played, PlayFailed, SttChunksSent, SttChunkFails, PartialsSeen;
        /// <summary>Raw PCM bytes sent (before base64).</summary>
        public static long SttBytesSent;
        /// <summary>Wav on disk to AudioClip, last load, milliseconds (0 on a cache hit).</summary>
        public static long LastLoadMs;

        // ------------------------------------------------------------ speech out

        private static readonly List<SpeechHandle> Live = new List<SpeechHandle>();
        private static AudioSource _flat;
        private static readonly List<GameObject> Spots = new List<GameObject>();   // pooled positional emitters

        /// <summary>
        /// Play one line. Main thread. Returns at once; the handle's events say
        /// what happened. A request with neither Wav nor Clip is a subtitle-only
        /// line: Started and Finished fire on the next tick and nothing beeps.
        /// </summary>
        public static SpeechHandle Say(SpeechRequest r)
        {
            var h = new SpeechHandle(r ?? new SpeechRequest());
            r = h.Request;
            var clip = r.Clip;
            if (clip == null && r.Wav.Length > 0)
            {
                string why;
                long t0 = AowlApi.NowMs;
                clip = LoadClip(r.Wav, out why);
                LastLoadMs = AowlApi.NowMs - t0;
                if (clip == null) { PlayFailed++; AowlApi.OnMain(() => h.RaiseFailed("wav not playable: " + why)); return h; }
            }
            if (clip == null)
            {
                if (r.VoiceSpec.Length > 0)
                {
                    PlayFailed++;
                    AowlApi.OnMain(() => h.RaiseFailed("nothing to synthesise with: the backend " + AowlBackend.BackendVersion +
                        " exposes no text-only TTS route (only /say, whose reply segments arrive with a wav). Pass Wav or Clip, or use AowlBrain.Ask."));
                    return h;
                }
                h.SubtitleOnly = true;
                AowlApi.OnMain(() => { h.RaiseStarted(); h.RaiseFinished(); });
                return h;
            }
            AudioSource src;
            if (r.At != null)
            {
                src = r.At.gameObject.GetComponent<AudioSource>() ?? r.At.gameObject.AddComponent<AudioSource>();
                src.spatialBlend = 1f; src.maxDistance = r.MaxDistance; src.rolloffMode = AudioRolloffMode.Linear;
            }
            else if (r.Position.HasValue)
            {
                src = Spot(r.Position.Value);
                src.spatialBlend = 1f; src.maxDistance = r.MaxDistance; src.rolloffMode = AudioRolloffMode.Linear;
            }
            else
            {
                if (_flat == null)
                {
                    _flat = AowlApi.Instance.gameObject.GetComponent<AudioSource>() ?? AowlApi.Instance.gameObject.AddComponent<AudioSource>();
                    _flat.spatialBlend = 0f;
                }
                src = _flat;
            }
            src.clip = clip;
            src.Play();
            h.Source = src; h.Seconds = clip.length; h.StartedAt = Time.unscaledTime;
            Played++;
            lock (Live) Live.Add(h);
            h.RaiseStarted();
            return h;
        }

        /// <summary>Shorthand: play <paramref name="wav"/> (or subtitle-only when "") at <paramref name="position"/> (2-D when null).</summary>
        public static SpeechHandle Say(string text, string wav, Vector3? position = null, string personId = "")
            => Say(new SpeechRequest { Text = text ?? "", Wav = wav ?? "", Position = position, PersonId = personId ?? "" });

        private static AudioSource Spot(Vector3 at)
        {
            foreach (var go in Spots)
            {
                var s = go.GetComponent<AudioSource>();
                if (s != null && !s.isPlaying) { go.transform.position = at; return s; }
            }
            var n = new GameObject("aowl-speech-" + Spots.Count);
            UnityEngine.Object.DontDestroyOnLoad(n);
            n.transform.position = at;
            var src = n.AddComponent<AudioSource>();
            Spots.Add(n);
            return src;
        }

        internal static void Tick()
        {
            List<SpeechHandle> done = null;
            lock (Live)
            {
                for (int i = Live.Count - 1; i >= 0; i--)
                {
                    var h = Live[i];
                    bool playing = false;
                    try { playing = h.Source != null && h.Source.isPlaying; } catch { }
                    // A source stolen by a later line on the same object reads !isPlaying too; either way this line is over.
                    if (playing && Time.unscaledTime - h.StartedAt < h.Seconds + 5f) continue;
                    Live.RemoveAt(i);
                    (done ?? (done = new List<SpeechHandle>())).Add(h);
                }
            }
            if (done != null) foreach (var h in done) h.RaiseFinished();
        }

        // ------------------------------------------------------------ the clip cache (wav -> AudioClip; from EFMB's AudioPlayback.cs, chunk-scanning)

        private sealed class Cached { public AudioClip Clip; public long Size; public DateTime Mtime; public long LastUse; }
        private static readonly Dictionary<string, Cached> Clips = new Dictionary<string, Cached>(StringComparer.OrdinalIgnoreCase);
        /// <summary>How many clips the cache keeps (least recently used is evicted).</summary>
        public static int ClipCacheMax = 64;
        /// <summary>Clips currently cached.</summary>
        public static int ClipCacheCount { get { lock (Clips) return Clips.Count; } }
        /// <summary>Cache hits / misses.</summary>
        public static int ClipHits, ClipMisses;

        /// <summary>
        /// A 16-bit PCM RIFF wav on disk as an AudioClip, cached by path + size
        /// + mtime (a re-synthesised file at the same path is reloaded). Main
        /// thread (AudioClip.Create). Null with the reason when it cannot be
        /// decoded; the reason names the file.
        /// </summary>
        public static AudioClip LoadClip(string path, out string why)
        {
            why = null;
            FileInfo fi;
            try { fi = new FileInfo(path); if (!fi.Exists) { why = "no such file: " + path; return null; } }
            catch (Exception ex) { why = "cannot stat " + path + ": " + ex.Message; return null; }
            lock (Clips)
            {
                if (Clips.TryGetValue(path, out var c) && c.Size == fi.Length && c.Mtime == fi.LastWriteTimeUtc && c.Clip != null)
                { c.LastUse = AowlApi.NowMs; ClipHits++; return c.Clip; }
            }
            ClipMisses++;
            var clip = Decode(path, out why);
            if (clip == null) return null;
            lock (Clips)
            {
                Clips[path] = new Cached { Clip = clip, Size = fi.Length, Mtime = fi.LastWriteTimeUtc, LastUse = AowlApi.NowMs };
                while (Clips.Count > ClipCacheMax)
                {
                    string oldest = null; long t = long.MaxValue;
                    foreach (var kv in Clips) if (kv.Value.LastUse < t) { t = kv.Value.LastUse; oldest = kv.Key; }
                    if (oldest == null) break;
                    try { UnityEngine.Object.Destroy(Clips[oldest].Clip); } catch { }
                    Clips.Remove(oldest);
                }
            }
            return clip;
        }

        /// <summary>Forget every cached clip.</summary>
        public static void ClearClipCache() { lock (Clips) { foreach (var kv in Clips) { try { UnityEngine.Object.Destroy(kv.Value.Clip); } catch { } } Clips.Clear(); } }

        private static AudioClip Decode(string path, out string why)
        {
            why = null;
            byte[] wav;
            try { wav = File.ReadAllBytes(path); }
            catch (Exception ex) { why = "cannot read " + path + ": " + ex.Message; return null; }
            if (wav.Length < 44 || wav[0] != 'R' || wav[1] != 'I' || wav[2] != 'F' || wav[3] != 'F' || wav[8] != 'W' || wav[9] != 'A' || wav[10] != 'V' || wav[11] != 'E')
            { why = "not a RIFF/WAVE file: " + path; return null; }
            int fmt = FindChunk(wav, "fmt ");
            int data = FindChunk(wav, "data");
            if (fmt < 0 || data < 0) { why = "no fmt/data chunk in " + path; return null; }
            int channels = I16(wav, fmt + 10);
            int rate = I32(wav, fmt + 12);
            int bits = I16(wav, fmt + 22);
            int size = I32(wav, data + 4);
            int start = data + 8;
            if (bits != 16) { why = "unsupported bit depth " + bits + " (want 16)"; return null; }
            if (channels < 1 || rate <= 0) { why = "absurd fmt: channels=" + channels + " rate=" + rate; return null; }
            if (start + size > wav.Length) size = wav.Length - start;
            int samples = size / 2;
            var f = new float[samples];
            for (int i = 0; i < samples; i++)
            {
                int b = start + i * 2;
                short v = (short)(wav[b] | (wav[b + 1] << 8));
                f[i] = v / 32768f;
            }
            var clip = AudioClip.Create("aowl-say", samples / channels, channels, rate, false);
            clip.SetData(f, 0);
            return clip;
        }

        private static int FindChunk(byte[] w, string id)
        {
            for (int i = 12; i < w.Length - 8; i++)
                if (w[i] == (byte)id[0] && w[i + 1] == (byte)id[1] && w[i + 2] == (byte)id[2] && w[i + 3] == (byte)id[3]) return i;
            return -1;
        }
        private static int I16(byte[] b, int o) => (short)(b[o] | (b[o + 1] << 8));
        private static int I32(byte[] b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

        // ------------------------------------------------------------ speech in: the chunk sender (lifted from Basement.Client/Hear.cs)

        internal sealed class Chunk { public ListenSession Session; public int Seq; public byte[] Pcm; public bool Final; public long UpAtMs; }
        private static readonly Queue<Chunk> Outbox = new Queue<Chunk>();
        private static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        private static Thread _sender;

        /// <summary>Open a push-to-talk session for <paramref name="personId"/> ("" = nobody). Any thread. Push audio, then Finish.</summary>
        public static ListenSession Listen(string personId)
        {
            var s = new ListenSession(personId, "spt-" + Guid.NewGuid().ToString("N"));
            EnsureSender();
            return s;
        }

        internal static void EnqueueChunk(Chunk c)
        {
            lock (Outbox) Outbox.Enqueue(c);
            Wake.Set();
        }

        private static void EnsureSender()
        {
            if (_sender != null && _sender.IsAlive) return;
            _sender = new Thread(SenderLoop) { IsBackground = true, Name = "aowl-api-stt" };
            _sender.Start();
        }

        private static void SenderLoop()
        {
            while (true)
            {
                Chunk c = null;
                lock (Outbox)
                {
                    if (Outbox.Count > 0)
                    {
                        c = Outbox.Dequeue();
                        // Coalesce: a partial's whisper pass runs INSIDE the chunk
                        // request (backend, under the mod lock), so chunks pile up
                        // behind it; merging them keeps seq dense and the audio whole.
                        while (Outbox.Count > 0 && !c.Final && Outbox.Peek().Session == c.Session)
                        {
                            var n = Outbox.Dequeue();
                            var merged = new byte[c.Pcm.Length + n.Pcm.Length];
                            Array.Copy(c.Pcm, merged, c.Pcm.Length);
                            Array.Copy(n.Pcm, 0, merged, c.Pcm.Length, n.Pcm.Length);
                            c.Pcm = merged; c.Final = n.Final; c.UpAtMs = n.UpAtMs;
                        }
                    }
                }
                if (c == null) { Wake.WaitOne(500); continue; }
                try { Send(c); }
                catch (Exception ex) { if (AowlApi.Once("stt-send-throw:" + ex.GetType().Name)) AowlApi.Log.LogError("aowl.api listen: sender threw " + ex); }
            }
        }

        private static void Send(Chunk c)
        {
            var s = c.Session;
            var body = new JObject { ["session"] = s.Id, ["seq"] = c.Seq, ["final"] = c.Final };
            if (c.Pcm.Length > 0) body["wavBase64"] = Convert.ToBase64String(c.Pcm);
            if (c.Seq == 0) body["personId"] = s.PersonId;   // section 6.7: the addressee travels in the first chunk
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            var r = AowlHttp.Post(AowlHttp.Route("/speech/chunk"), text, c.Final ? 120000 : 30000);
            if (!r.Ok)
            {
                SttChunkFails++;
                if (AowlApi.Once("chunk-fail:" + r.Status + ":" + r.Err))
                    AowlApi.Log.LogWarning("aowl.api listen: POST /speech/chunk seq " + c.Seq + (c.Final ? " (final)" : "") + " answered " + r.Err + " (HTTP " + r.Status + "). Said once per status and note.");
                var why = r.Err; bool fin = c.Final;
                AowlApi.OnMain(() => s.RaiseFailed(why, fin));
                return;
            }
            SttChunksSent++;
            SttBytesSent += c.Pcm.Length;
            var partial = r.Json.Value<string>("partial") ?? "";
            var note = r.Json.Value<string>("note") ?? "";
            if (partial.Length > 0) { PartialsSeen++; AowlApi.OnMain(() => s.RaisePartial(partial)); }
            if (!c.Final) return;
            var res = new ListenResult
            {
                Text = r.Json.Value<string>("final") ?? "", Note = note,
                SpokeTo = r.Json["spokeTo"] != null ? (r.Json.Value<string>("spokeTo") ?? "") : null,
                Reply = r.Json.Value<string>("reply") ?? "", SayNote = r.Json.Value<string>("sayNote") ?? "",
                ElapsedMs = c.UpAtMs > 0 ? AowlApi.NowMs - c.UpAtMs : 0, Raw = r.Json,
            };
            AowlApi.Log.LogInfo("aowl.api listen: final for " + s.Id + " after " + res.ElapsedMs + " ms: \"" + res.Text + "\" -- " + note +
                (res.SpokeTo != null ? " (backend asked: '" + res.SpokeTo + "')" : " (backend did not ask the brain)"));
            AowlApi.OnMain(() => s.RaiseFinal(res));
        }

        /// <summary>
        /// The backend-recorder fallback: POST /speech/ptt {session, state:
        /// "down"|"up"|"poll", personId}. The backend records on ITS machine.
        /// Any thread; <paramref name="done"/> runs on the main thread with the
        /// answer (Ok false = refused; on "up" Json["final"] is the transcript,
        /// "" = not transcribed, and Json["spokeTo"] says whether the brain was asked).
        /// </summary>
        public static void PushToTalk(string session, string state, string personId, Action<AowlHttp.Reply> done)
        {
            var body = new JObject { ["session"] = session ?? "", ["state"] = state ?? "", ["personId"] = personId ?? "" };
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            Task.Run(async () =>
            {
                var r = await AowlHttp.PostAsync(AowlHttp.Route("/speech/ptt"), text, 15000).ConfigureAwait(false);
                if (done != null) AowlApi.OnMain(() => done(r));
            });
        }
    }
}
