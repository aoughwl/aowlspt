using System;
using System.Collections.Generic;
using System.IO;
using Aowl.Api;
using EFT;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// Playing `say` segments (CLIENT-CONTRACT section 7). One queue per
    /// personId, drained back to back in seq order; nothing waits for `final`.
    /// A wav path is read directly: the backend runs on this machine. A
    /// segment with wav=="" is shown as a subtitle and never replaced by a beep.
    /// A new utterance (segmentIdx 0) for a person flushes what that person
    /// has not played yet. An out-of-order segmentIdx is held up to 2 s, then
    /// what is there is played and the gap is logged.
    ///
    /// Unlike the aowlspt host verb, AudioSource.isPlaying IS a completion
    /// signal, so segments are paced by their real length here.
    /// </summary>
    internal static class Say
    {
        private sealed class Segment
        {
            public string PersonId; public long Seq; public int Idx; public string Wav; public string Text; public bool Final; public bool AckWanted;
            // The hearing model (CLIENT-CONTRACT section 7): how far away the
            // speaker is and how loudly they are saying it.
            public float DistanceM; public string Mode; public bool Reaction;
        }

        private sealed class Channel
        {
            public readonly List<Segment> Pending = new List<Segment>();
            public int NextIdx;            // the segmentIdx expected next
            public float HeldSince = -1f;  // when a gap was first noticed
            public AudioSource Source;     // the source the last segment plays on
            public Segment Playing;
        }

        private const float GapHoldSeconds = 2f;
        private const float MaxDistance = 40f;

        // The backend decides WHO can hear a line; these turn that decision
        // into audio. `SpeakVolume` is deliberately 0.5 and `YellVolume` 1.0 --
        // exactly +6 dB -- so a shout is louder than a spoken line rather than
        // merely reaching further. If the TTS engine already shouted (the
        // backend put `yell:true` in the voiceSpec and agent Q's engine acted
        // on it) this is on top of that and is meant to be: a recorded shout
        // played at conversational volume still sounds like a conversation.
        private const float SpeakVolume = 0.5f;
        private const float YellVolume = 1.0f;
        private const float MutterVolume = 0.3f;
        private const float YellPitch = 1.06f;

        private static readonly Dictionary<string, Channel> Channels = new Dictionary<string, Channel>(StringComparer.Ordinal);
        private static AudioSource _flat;   // the 2-D fallback source, on the plugin object
        public static int Segments, Subtitles, Flushes, Gaps, Played, Failed;
        /// <summary>Segments the BACKEND marked audible:false. They are never played and never subtitled.</summary>
        public static int Inaudible, Yells, Mutters;
        /// <summary>The hearing range the backend last reported, for the HUD and for /status.</summary>
        public static float LastYellM = 70f, LastSpeakM = 25f;
        public static string LastLine = "";
        public static long SayStartedMs = -1;   // transcript landed (Hear.HeardFinalAtMs) -> first audio of the reply started
        public static long LastLoadMs;          // wav on disk -> AudioClip, last segment

        /// <summary>
        /// The hearing-aware entry point: it reads `audible`, `mode` and
        /// `distanceM` off the raw event, because <see cref="SaySegment"/> is
        /// the shared API's shape and does not carry them.
        ///
        /// An `audible:false` segment is DROPPED here, not played quietly: the
        /// backend has already decided the player could not have heard it, and
        /// journaled `say.suppressed` on its side. Playing it faintly would put
        /// a voice in the player's ear that the world says is not there.
        /// </summary>
        public static void Enqueue(SaySegment s, AowlEvent e)
        {
            var d = e.Data;
            bool audible = d.Value<bool?>("audible") ?? true;
            string mode = d.Value<string>("mode") ?? "speak";
            float dist = d.Value<float?>("distanceM") ?? -1f;
            bool reaction = d.Value<bool?>("reaction") ?? false;
            LastSpeakM = d.Value<float?>("hearSpeakM") ?? LastSpeakM;
            LastYellM = d.Value<float?>("hearYellM") ?? LastYellM;
            if (!audible)
            {
                Inaudible++;
                if (Plugin.Once("inaudible:" + (s.PersonId ?? "")))
                    Plugin.Log.LogInfo("basement say: dropped a line from " + People.NameOf(s.PersonId) +
                        " at " + dist.ToString("0") + " m -- the backend marked it audible:false (" +
                        (d.Value<string>("hearingNote") ?? "beyond yelling range") +
                        "). Said once per person; the count is on /status.");
                return;
            }
            Enqueue(s.PersonId, s.Seq, s.SegmentIdx, s.Wav, s.Text, s.Final, e.WantsAck, dist, mode, reaction);
        }

        public static void Enqueue(string personId, long seq, int idx, string wav, string text, bool final, bool ackWanted)
            => Enqueue(personId, seq, idx, wav, text, final, ackWanted, -1f, "speak", false);

        public static void Enqueue(string personId, long seq, int idx, string wav, string text, bool final, bool ackWanted,
                                   float distanceM, string mode, bool reaction)
        {
            var key = personId ?? "";
            if (!Channels.TryGetValue(key, out var ch)) { ch = new Channel(); Channels[key] = ch; }
            if (idx == 0)
            {
                int dropped = ch.Pending.Count;
                if (dropped > 0)
                {
                    Flushes++;
                    Plugin.Log.LogInfo("basement say: flushed " + dropped + " unplayed segment(s) for " + key + " -- a new utterance superseded them.");
                }
                ch.Pending.Clear();
                ch.NextIdx = 0;
                ch.HeldSince = -1f;
            }
            ch.Pending.Add(new Segment { PersonId = key, Seq = seq, Idx = idx, Wav = wav ?? "", Text = text ?? "", Final = final, AckWanted = ackWanted,
                                         DistanceM = distanceM, Mode = mode ?? "speak", Reaction = reaction });
            ch.Pending.Sort((a, b) => a.Seq.CompareTo(b.Seq));
        }

        public static void Tick()
        {
            foreach (var kv in Channels)
            {
                var ch = kv.Value;
                if (ch.Playing != null)
                {
                    if (ch.Source != null && ch.Source.isPlaying) continue;
                    ch.Playing = null;
                }
                if (ch.Pending.Count == 0) continue;
                var head = ch.Pending[0];
                if (head.Idx > ch.NextIdx)
                {
                    // A gap. Hold briefly; then play what is there and say so.
                    if (ch.HeldSince < 0) { ch.HeldSince = Time.unscaledTime; continue; }
                    if (Time.unscaledTime - ch.HeldSince < GapHoldSeconds) continue;
                    Gaps++;
                    Plugin.Log.LogWarning("basement say: segment " + ch.NextIdx + " for " + kv.Key + " never arrived within " + GapHoldSeconds +
                        " s; playing from segment " + head.Idx + ". If the link reported a hole, that is why.");
                }
                ch.HeldSince = -1f;
                ch.Pending.RemoveAt(0);
                ch.NextIdx = head.Idx + 1;
                Play(ch, head);
            }
        }

        private static void Play(Channel ch, Segment s)
        {
            Segments++;
            LastLine = s.Text;
            var who = People.NameOf(s.PersonId);
            if (s.Mode == "yell") Yells++;
            else if (s.Mode == "mutter") Mutters++;
            // Only an audible segment reaches Play() at all (Enqueue drops the
            // rest), so every subtitle drawn is a line the player could hear.
            if (s.Text.Length > 0) Hud.Subtitle(who, s.Text, s.DistanceM, s.Mode);
            if (s.Wav.Length == 0)
            {
                Subtitles++;
                Plugin.Log.LogInfo("basement say [" + s.PersonId + " seg " + s.Idx + "]: " + s.Text + "  (no wav -- TTS is off, missing or failed; the text IS the line)");
                if (s.AckWanted) Plugin.Link.Ack(s.Seq, true, "shown as a subtitle; the segment carried no wav path");
                return;
            }
            string why;
            long t0 = Plugin.NowMs;
            var clip = LoadClip(s.Wav, out why);
            LastLoadMs = Plugin.NowMs - t0;
            if (clip == null)
            {
                Failed++;
                Plugin.Log.LogWarning("basement say [" + s.PersonId + " seg " + s.Idx + "]: subtitle only -- " + why);
                if (s.AckWanted) Plugin.Link.Ack(s.Seq, false, "wav not playable: " + why);
                return;
            }
            var bot = People.BotFor(s.PersonId);
            AudioSource src;
            if (bot != null)
            {
                src = bot.gameObject.GetComponent<AudioSource>() ?? bot.gameObject.AddComponent<AudioSource>();
                src.spatialBlend = 1f;
                // A shout has to REACH: at the default 40 m rolloff a yell the
                // backend sent for a 60 m gap would have been inaudible on
                // arrival, which is the same bug in the opposite direction.
                src.maxDistance = s.Mode == "yell" ? Mathf.Max(LastYellM, MaxDistance) : MaxDistance;
                src.rolloffMode = AudioRolloffMode.Linear;
            }
            else
            {
                if (_flat == null)
                {
                    _flat = Plugin.Instance.gameObject.GetComponent<AudioSource>() ?? Plugin.Instance.gameObject.AddComponent<AudioSource>();
                    _flat.spatialBlend = 0f;
                }
                src = _flat;
                if (Plugin.Once("say-2d:" + s.PersonId))
                    Plugin.Log.LogInfo("basement say: person " + s.PersonId + " is not mapped to a live bot; playing 2-D. Said once per person.");
            }
            src.clip = clip;
            src.volume = s.Mode == "yell" ? YellVolume : (s.Mode == "mutter" ? MutterVolume : SpeakVolume);
            src.pitch = s.Mode == "yell" ? YellPitch : 1f;
            src.Play();
            ch.Source = src;
            ch.Playing = s;
            Played++;
            // The reply's FIRST audible segment after a transcript: that gap is
            // what the player feels as "how long until they answer".
            if (Hear.HeardFinalAtMs > 0)
            {
                SayStartedMs = Plugin.NowMs - Hear.HeardFinalAtMs;
                Hear.HeardFinalAtMs = 0;
                Plugin.Log.LogInfo("basement say: first audio " + SayStartedMs + " ms after the transcript (seg " + s.Idx + " of " + who + ", clip " + clip.length.ToString("0.00") + " s, wav->clip " + LastLoadMs + " ms).");
            }
            if (s.AckWanted) Plugin.Link.Ack(s.Seq, true, "playing " + s.Wav + (bot != null ? " at bot " + bot.ProfileId : " (2-D)"));
        }

        // ------------------------------------------------------------ wav -> AudioClip (from EFMB's AudioPlayback.cs, chunk-scanning)

        private static AudioClip LoadClip(string path, out string why)
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
            var clip = AudioClip.Create("basement-say", samples / channels, channels, rate, false);
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
    }
}
