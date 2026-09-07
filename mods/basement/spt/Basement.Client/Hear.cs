using System;
using System.Collections.Generic;
using Aowl.Api;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// Push-to-talk, two ways.
    ///
    /// MIC MODE (default, Voice.CaptureInProcess=true): while the key is held
    /// the microphone is captured IN-PROCESS with UnityEngine.Microphone into a
    /// 30 s looping clip; every Voice.ChunkMs the new samples are read off the
    /// ring on the main thread and pushed into an Aowl.Api ListenSession,
    /// which resamples to 16 kHz mono PCM16 and POSTs the chunks in order to
    /// /speech/chunk {session, seq, wavBase64, final, personId@seq0}. The backend runs
    /// whisper on the growing buffer and answers partials; key-up sends
    /// final:true (with the last samples) and the reply carries the transcript.
    ///
    /// BACKEND MODE (fallback): when Microphone.devices is empty, Start returns
    /// null, or CaptureInProcess is off, down/up are POSTed to /speech/ptt and
    /// the backend records on this machine, as before. The fallback is said
    /// ONCE with the reason; the mode is in the status line.
    ///
    /// THE BRAIN: the final reply's `spokeTo` says whether the backend handed
    /// the transcript to the brain itself (ListenResult.SpokeTo != null). An
    /// older backend's chunk route did not (MEASURED 2026-09-07), so when it
    /// is absent this client asks through AowlBrain.Ask (POST /say) itself.
    ///
    /// The addressee is latched at key down (CLIENT-CONTRACT section 6.6) and
    /// named in the first chunk / the down post; `final` / `up` is always sent,
    /// including on cancel, so a session never leaks a buffer.
    /// </summary>
    internal static class Hear
    {
        public static bool Holding;
        public static string Session = "";
        public static string LatchedPerson;
        public static string LatchedName;
        public static int Sessions, Downs, Ups, Refused;

        // ---- the status counters ----
        public static volatile string Mode = "none";      // mic | backend | none
        public static int PartialsShown, MicFails, BrainAsks;
        public static int SttChunksSent => AowlSpeech.SttChunksSent;
        public static int SttChunkFails => AowlSpeech.SttChunkFails;
        public static long SttBytesSent => AowlSpeech.SttBytesSent;   // raw PCM bytes (before base64)
        public static volatile string MicNote = "not tried";
        public static int MicRate;                          // the frequency Unity actually granted
        public static int MicWarmupMs = -1;                 // Start() -> first sample, measured once per session
        public static long HeardFinalAtMs;                  // Plugin.NowMs when the transcript landed; Say reads and clears it
        public static long LastFinalMs;                     // key-up -> transcript, last session

        private const float MaxUtteranceSeconds = 28f;      // section 3: split anything near 30 s

        // ---- capture (main thread only) ----
        private static AudioClip _clip;
        private static string _dev;
        private static int _readPos;
        private static bool _prewarmFailed;
        private static float _lastChunkAt, _downAt, _startedAt;
        private static string _lastPartial = "";
        private static long _upAtMs;
        private static ListenSession _listen;              // the API session for the current mic-mode utterance

        public static void Tick()
        {
            if (!Plugin.Started) return;
            var key = Plugin.PushToTalkKey.Value;
            if (key == KeyCode.None) return;
            // Pre-warm: open the device the moment a raid starts, off the press
            // path, and close it when the raid ends. A failure is noted once and
            // the press falls back to the backend recorder as before.
            if (See.InRaid && _clip == null && Plugin.CaptureInProcess.Value && !_prewarmFailed)
            {
                string pw;
                if (!StartMic(out pw)) { _prewarmFailed = true; if (Plugin.Once("mic-prewarm")) Plugin.Log.LogWarning("basement hear: could not pre-open the microphone at raid start (" + pw + "); presses will use the backend recorder."); }
                else if (Plugin.Once("mic-prewarm-ok")) Plugin.Log.LogInfo("basement hear: microphone pre-opened at raid start and kept running; a press only marks the read position.");
            }
            else if (!See.InRaid && _clip != null) { StopMic(); _prewarmFailed = false; }
            if (!Holding && Input.GetKeyDown(key)) Down();
            else if (Holding && (Input.GetKeyUp(key) || !Input.GetKey(key))) Up();
            if (Holding && Mode == "mic")
            {
                if (Time.unscaledTime - _downAt > MaxUtteranceSeconds) Rollover();
                else PumpMic(false);
            }
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
            LatchedPerson = who;
            LatchedName = who != null ? People.NameOf(who) : null;
            _lastPartial = "";
            _downAt = Time.unscaledTime;
            string why = null;
            if (Plugin.CaptureInProcess.Value && StartMic(out why))
            {
                Mode = "mic";
                OpenSession();
                return;
            }
            Session = "spt-" + Guid.NewGuid().ToString("N");
            if (Plugin.CaptureInProcess.Value)
            {
                MicFails++;
                MicNote = why;
                if (Plugin.Once("mic-fallback:" + why))
                    Plugin.Log.LogWarning("basement hear: in-process capture is unavailable -- " + why +
                        ". Falling back to the backend recorder (/speech/ptt). Said once per reason.");
            }
            Mode = "backend";
            Post("down");
        }

        private static void Up()
        {
            if (!Holding) return;
            Holding = false;
            Ups++;
            _upAtMs = Plugin.NowMs;
            if (Mode == "mic")
            {
                PumpMic(true);
                // The device stays open until the raid ends (see Tick): closing
                // and reopening it per press is what hitched the main thread.
            }
            else Post("up");
        }

        /// <summary>The key is still down past the utterance cap: close this session and open the next with the same addressee.</summary>
        private static void Rollover()
        {
            PumpMic(true);
            Plugin.Log.LogInfo("basement hear: the key has been held " + MaxUtteranceSeconds + " s -- session " + Session + " finalised and a new one opened for " + (LatchedName ?? "nobody") + " (whisper's cost is superlinear in buffer length).");
            OpenSession();
            Sessions++;
            _downAt = Time.unscaledTime;
            _lastPartial = "";
            _upAtMs = 0;
        }

        // ------------------------------------------------------------ microphone

        private static bool StartMic(out string why)
        {
            why = null;
            string[] devs;
            try { devs = Microphone.devices; }
            catch (Exception ex) { why = "Microphone.devices threw " + ex.GetType().Name + ": " + ex.Message; return false; }
            if (devs == null || devs.Length == 0) { why = "Microphone.devices is empty (no capture device, or the game holds the microphone exclusively)"; return false; }
            _dev = null;
            var want = Plugin.MicDevice.Value ?? "";
            if (want.Length > 0)
            {
                foreach (var d in devs) if (string.Equals(d, want, StringComparison.OrdinalIgnoreCase)) { _dev = d; break; }
                if (_dev == null && Plugin.Once("mic-device-missing:" + want))
                    Plugin.Log.LogWarning("basement hear: Voice.MicDevice `" + want + "` is not among [" + string.Join(" | ", devs) + "]; using the default device.");
            }
            int freq = 16000;
            try
            {
                Microphone.GetDeviceCaps(_dev, out var min, out var max);
                // (0,0) means any frequency; otherwise clamp and let Pcm.cs resample.
                if (!(min == 0 && max == 0)) { if (freq < min) freq = min; else if (freq > max) freq = max; }
            }
            catch (Exception ex) { if (Plugin.Once("mic-caps")) Plugin.Log.LogInfo("basement hear: GetDeviceCaps threw " + ex.Message + "; asking for 16000 Hz anyway."); }
            // The device is opened ONCE per raid and kept running; a press only
            // moves the read position. MEASURED 2026-09-07: opening the device on
            // every V press stalled the main thread long enough that the player
            // floated upward and snapped back on release (the game's position
            // correction after a hitch).
            bool running = false;
            try { running = _clip != null && Microphone.IsRecording(_dev); } catch { running = false; }
            if (running)
            {
                try { _readPos = Microphone.GetPosition(_dev); } catch { _readPos = 0; }
                _startedAt = Time.unscaledTime;
                _lastChunkAt = _startedAt;
                MicWarmupMs = 0;
                return true;
            }
            try
            {
                if (_clip != null) StopMic();
                _clip = Microphone.Start(_dev, true, 30, freq);
            }
            catch (Exception ex) { why = "Microphone.Start threw " + ex.GetType().Name + ": " + ex.Message; _clip = null; return false; }
            if (_clip == null) { why = "Microphone.Start(" + (_dev ?? "default") + ", loop, 30 s, " + freq + " Hz) returned null"; return false; }
            MicRate = _clip.frequency;
            _readPos = 0;
            _startedAt = Time.unscaledTime;
            _lastChunkAt = _startedAt;
            MicWarmupMs = -1;
            MicNote = "capturing " + (_dev ?? "default device") + " @ " + MicRate + " Hz -> 16000 (clip " + _clip.samples + " samples, " + _clip.channels + " ch)";
            if (Plugin.Once("mic-ok"))
                Plugin.Log.LogInfo("basement hear: in-process capture works -- devices [" + string.Join(" | ", devs) + "]; " + MicNote +
                    ". The game did NOT hold the microphone exclusively. Said once.");
            return true;
        }

        private static void StopMic()
        {
            try { if (_clip != null) Microphone.End(_dev); } catch (Exception ex) { Plugin.Log.LogWarning("basement hear: Microphone.End threw " + ex.Message); }
            _clip = null;
        }

        /// <summary>Main thread. Reads what the ring has written since the last read and enqueues it.</summary>
        private static void PumpMic(bool final)
        {
            if (_clip == null) { if (final) Enqueue(new byte[0], true); return; }
            int pos;
            try { pos = Microphone.GetPosition(_dev); }
            catch (Exception ex) { if (Plugin.Once("mic-pos")) Plugin.Log.LogWarning("basement hear: GetPosition threw " + ex.Message); if (final) Enqueue(new byte[0], true); return; }
            if (pos > 0 && MicWarmupMs < 0)
            {
                MicWarmupMs = (int)((Time.unscaledTime - _startedAt) * 1000f);
                if (Plugin.Once("mic-warmup")) Plugin.Log.LogInfo("basement hear: the microphone delivered its first sample " + MicWarmupMs + " ms after Start(). Said once; the value is in the status line.");
            }
            if (!final && (Time.unscaledTime - _lastChunkAt) * 1000f < Plugin.ChunkMs.Value) return;
            _lastChunkAt = Time.unscaledTime;
            int total = _clip.samples;
            int avail = pos >= _readPos ? pos - _readPos : (total - _readPos) + pos;
            if (avail <= 0) { if (final) Enqueue(new byte[0], true); return; }
            if (avail > total) avail = total;
            float[] samples;
            try
            {
                if (pos >= _readPos)
                {
                    samples = new float[avail];
                    _clip.GetData(samples, _readPos);
                }
                else
                {
                    var head = new float[total - _readPos];
                    _clip.GetData(head, _readPos);
                    var tail = new float[pos];
                    if (pos > 0) _clip.GetData(tail, 0);
                    samples = new float[head.Length + tail.Length];
                    Array.Copy(head, samples, head.Length);
                    Array.Copy(tail, 0, samples, head.Length, tail.Length);
                }
            }
            catch (Exception ex)
            {
                if (Plugin.Once("mic-getdata")) Plugin.Log.LogWarning("basement hear: AudioClip.GetData threw " + ex.Message + "; this chunk is lost.");
                if (final) Enqueue(new byte[0], true);
                return;
            }
            _readPos = pos;
            // A multi-channel clip: take channel 0 only.
            if (_clip.channels > 1)
            {
                int ch = _clip.channels;
                var mono = new float[samples.Length / ch];
                for (int i = 0; i < mono.Length; i++) mono[i] = samples[i * ch];
                samples = mono;
            }
            if (_listen != null) _listen.Push(samples, samples.Length, MicRate, final);
        }

        private static void Enqueue(byte[] pcm, bool final)
        {
            if (_listen == null) return;
            _listen.Push(pcm, final);
        }

        // ------------------------------------------------------------ the API session (chunks go through Aowl.Api's sender thread)

        /// <summary>Main thread. One ListenSession per utterance; its events land on the main thread.</summary>
        private static void OpenSession()
        {
            var person = LatchedPerson ?? "";
            var sess = AowlSpeech.Listen(person);
            _listen = sess;
            Session = sess.Id;
            sess.Partial += ShowPartial;
            sess.Failed += (why, final) =>
            {
                if (final) Hud.Warn("talk: " + why, 4f);
            };
            sess.Final += res =>
            {
                if (res.ElapsedMs > 0) LastFinalMs = res.ElapsedMs;
                var fin = res.Text ?? "";
                var note = res.Note ?? "";
                if (fin.Length == 0) { Hud.Warn("not transcribed" + (note.Length > 0 ? ": " + note : "")); return; }
                Hud.Note("you: " + fin);
                if (HeardFinalAtMs == 0) HeardFinalAtMs = Plugin.NowMs;
                if (res.SpokeTo != null) return;   // the backend already asked the brain (or explained why not in SayNote)
                AskBrain(person, fin);
            };
        }

        /// <summary>Main thread. AowlBrain.Ask (POST /say {person, text}); the reply's segments arrive on the event stream as `say`.</summary>
        private static void AskBrain(string person, string text)
        {
            if (string.IsNullOrEmpty(person))
            {
                if (Plugin.Once("brain-nobody")) Plugin.Log.LogInfo("basement hear: transcript with no addressee -- nobody is asked (TalkNeedsAddressee=false). Said once.");
                Hud.Warn("nobody was addressed; the line went to no one", 3f);
                return;
            }
            if (Plugin.Once("brain-via-say"))
                Plugin.Log.LogInfo("basement hear: /speech/chunk's final reply carried no `spokeTo`, so this client hands the transcript to the brain itself via AowlBrain.Ask. Said once.");
            BrainAsks++;
            var ask = AowlBrain.Ask(person, text);
            ask.Failed += why => Hud.Warn("no answer: " + why, 4f);
            ask.Answered += r => Plugin.Log.LogInfo("basement hear: /say answered for " + People.NameOf(person) + " -- tier=" + r.Tier + " engine=" + r.Engine + " ms=" + r.Ms +
                " (the segments play from the event stream, not from this reply)");
        }

        // ------------------------------------------------------------ shared with Link (main thread)

        public static void ShowPartial(string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            if (text != _lastPartial) { PartialsShown++; _lastPartial = text; }
            Hud.Note("(hearing) " + text, 3f);
        }

        /// <summary>A heard.final from the stream (the backend-recorder path, or the chunk path's own emit).</summary>
        public static void OnHeardFinalEvent(string text)
        {
            if (text.Length > 0 && HeardFinalAtMs == 0) HeardFinalAtMs = Plugin.NowMs;
            if (_upAtMs > 0 && Mode == "backend") { LastFinalMs = Plugin.NowMs - _upAtMs; _upAtMs = 0; }
        }

        // ------------------------------------------------------------ backend-recorder mode (/speech/ptt)

        private static void Post(string state)
        {
            AowlSpeech.PushToTalk(Session, state, LatchedPerson ?? "", r =>
            {
                if (!r.Ok)
                {
                    if (Plugin.Once("ptt-fail:" + state + ":" + r.Status))
                        Plugin.Log.LogWarning("basement hear: POST /speech/ptt " + state + " answered " + r.Err + " (HTTP " + r.Status + "). Said once per state and status.");
                    Hud.Warn("talk: " + r.Err, 4f);
                    return;
                }
                var note = r.Json.Value<string>("note") ?? "";
                if (state == "up")
                {
                    var fin = r.Json.Value<string>("final") ?? "";
                    if (fin.Length == 0) Hud.Warn("not transcribed" + (note.Length > 0 ? ": " + note : ""));
                }
                Plugin.Log.LogInfo("basement hear: ptt " + state + " ok " + note);
            });
        }
    }
}
