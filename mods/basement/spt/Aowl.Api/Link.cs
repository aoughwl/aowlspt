using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using BepInEx;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>
    /// The long poll, the dispatch and the ack -- a mirror of
    /// mods/basement/bridge/link.nim, lifted from Basement.Client/Link.cs.
    ///
    /// ONE REQUEST IN FLIGHT AT A TIME: the loop is a single thread, so two
    /// overlapping polls with the same `since` (which would execute every
    /// directive twice) cannot happen by construction.
    ///
    /// THE CURSOR advances only to seqs we actually parsed and is persisted to
    /// BepInEx/config/aowl.api.cursor so a restart does not replay old
    /// directives. `firstSeq` is the hole detector (CLIENT-CONTRACT section 4):
    /// a cursor older than firstSeq-1 means PROVABLY missed events, announced
    /// loudly and resynced to latestSeq, never resumed silently.
    ///
    /// DISPATCH IS BY KIND through <see cref="AowlEvents"/>: a registered
    /// handler gets the event; an unknown directive is ACKED ok:false with
    /// "unsupported kind", never ignored. Every directive is acked exactly once.
    /// </summary>
    public sealed class Link
    {
        private const int RetryMs = 3000;
        private const int Limit = 64;

        private Thread _thread;
        private volatile bool _running;
        private long _since;
        private int _transportFails;
        private long _latest;
        private long _first;
        private bool _haveCursor;
        private string _cursorFile;

        /// <summary>The last seq consumed (persisted).</summary>
        public long Cursor => _since;
        /// <summary>The backend's latestSeq from the last batch.</summary>
        public long LatestSeq => _latest;
        /// <summary>The backend's firstSeq from the last batch (the ring's oldest seq).</summary>
        public long FirstSeq => _first;
        /// <summary>Counters for the status line.</summary>
        public int Polls, Batches, Events, Directives, Unsupported, Holes, Observed, Acks;
        /// <summary>One word on what the loop is doing: idle / polling / poll failed / backend refused / stopped / resynced...</summary>
        public volatile string State = "idle";
        /// <summary>The last poll failure reason.</summary>
        public volatile string LastError = "";

        internal void Start()
        {
            if (_running) return;
            // Fully qualified: Assembly-CSharp declares a global `Paths` type that shadows BepInEx.Paths (measured at compile).
            _cursorFile = Path.Combine(BepInEx.Paths.ConfigPath, "aowl.api.cursor");
            try
            {
                // Adopt the pre-split Basement.Client cursor once, so the first run after the split does not replay the ring.
                var old = Path.Combine(BepInEx.Paths.ConfigPath, "aowl.basement.cursor");
                if (!File.Exists(_cursorFile) && File.Exists(old)) File.Copy(old, _cursorFile);
                if (File.Exists(_cursorFile) && long.TryParse(File.ReadAllText(_cursorFile).Trim(), out var c) && c > 0)
                {
                    _since = c;
                    _haveCursor = true;
                }
            }
            catch (Exception ex) { AowlApi.Log.LogWarning("aowl.api link: cursor file unreadable: " + ex.Message); }
            _running = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "aowl-api-link" };
            _thread.Start();
        }

        internal void Stop() { _running = false; }

        private void Loop()
        {
            // No stored cursor: probe with wait=0 and start at latestSeq rather than
            // replaying whatever the ring holds from before this client existed.
            if (!_haveCursor)
            {
                var probe = AowlHttp.Get(AowlHttp.Route("/events") + "?since=0&wait=0&limit=1", 10000);
                if (probe.Ok)
                {
                    _since = probe.Json.Value<long?>("latestSeq") ?? 0;
                    _haveCursor = true;
                    AowlApi.Log.LogInfo("aowl.api link: no stored cursor; starting at latestSeq " + _since + " (the ring history is NOT replayed).");
                    SaveCursor();
                }
            }
            bool immediate = false;
            while (_running)
            {
                int wait = immediate ? 0 : Math.Max(0, Math.Min(25000, AowlApi.PollWaitMs.Value));
                var url = AowlHttp.Route("/events") + "?since=" + _since + "&wait=" + wait + "&limit=" + Limit;
                Polls++;
                var r = AowlHttp.Get(url, wait + 10000);
                if (!_running) break;
                if (r.Error != null || r.Status != 200 || r.Json == null)
                {
                    State = "poll failed";
                    LastError = r.Err;
                    if (AowlApi.Once("poll-fail:" + r.Status + ":" + r.Error))
                        AowlApi.Log.LogWarning("aowl.api link: the long poll failed -- HTTP " + r.Status +
                            (r.Error != null ? ", transport: " + r.Error : "") + ". Cursor unchanged (" + _since +
                            "), retrying every " + RetryMs + " ms. Said once per status.");
                    immediate = false;
                    // A TRANSPORT failure (HTTP 0) three polls running means the
                    // sidecar is gone, not busy. MEASURED 2026-09-07: the backend
                    // died on an AssertionDefect mid-raid and every request failed
                    // for the rest of the raid. EnsureSidecar() is idempotent: it
                    // returns at once when /status answers or another backend
                    // process exists, so this cannot start a second one.
                    if (r.Error != null && r.Status == 0) _transportFails++; else _transportFails = 0;
                    if (_transportFails == 3 && AowlApi.SidecarAutoStart.Value)
                    {
                        AowlApi.Log.LogWarning("aowl.api link: 3 transport failures in a row -- asking EnsureSidecar() to restart the backend.");
                        try { AowlBackend.EnsureSidecar(); } catch (Exception ex) { AowlApi.Log.LogWarning("aowl.api link: EnsureSidecar threw " + ex.Message); }
                        _transportFails = 0;
                    }
                    Thread.Sleep(RetryMs);
                    continue;
                }
                _transportFails = 0;
                immediate = Consume(r.Json);
            }
            State = "stopped";
        }

        /// <summary>Returns true when the batch was full and the next poll should not wait.</summary>
        private bool Consume(JObject o)
        {
            Batches++;
            if (!(o.Value<bool?>("ok") ?? false))
            {
                State = "backend refused";
                if (AowlApi.Once("events-notok")) AowlApi.Log.LogWarning("aowl.api link: GET /events did not answer ok:true: " + o.ToString(Newtonsoft.Json.Formatting.None));
                Thread.Sleep(RetryMs);
                return false;
            }
            _latest = o.Value<long?>("latestSeq") ?? 0;
            _first = o.Value<long?>("firstSeq") ?? 0;
            if (_since > _latest)
            {
                // The backend RESTARTED (its stream begins again at 1) while our
                // cursor still points past its new end: every poll answers an
                // empty page for ever. MEASURED 2026-09-07: cursor ~300 against a
                // fresh sidecar at 17 -- transcripts and replies flowed on the
                // backend and the game showed nothing. Rewind to the start of the
                // new ring so the few events since the restart are replayed.
                AowlApi.Log.LogWarning("aowl.api link: the backend restarted -- cursor " + _since + " is past its latestSeq " +
                    _latest + ". Rewinding to " + Math.Max(0, _first - 1) + " and replaying the new ring.");
                _since = Math.Max(0, _first - 1);
                SaveCursor();
                State = "rewound after a backend restart";
                AowlEvents.RaiseResync("backend restart");
                return true;
            }
            if (_since > 0 && _first > 0 && _since < _first - 1)
            {
                Holes++;
                AowlApi.Log.LogWarning("aowl.api link: PROVABLY MISSED EVENTS -- cursor " + _since + ", ring starts at " + _first +
                    ". Resyncing to " + _latest + "; consumers re-read /world/people on Resync; everything between is gone.");
                _since = _latest;
                SaveCursor();
                State = "resynced after a hole";
                AowlEvents.RaiseResync("hole");
                return false;
            }
            var evts = o["events"] as JArray;
            int n = evts?.Count ?? 0;
            for (int i = 0; i < n; i++)
            {
                var e = evts[i] as JObject;
                if (e == null) continue;
                long seq = e.Value<long?>("seq") ?? 0;
                string kind = e.Value<string>("kind") ?? "";
                var data = e["data"] as JObject ?? new JObject();
                // The ack flag and ttl are SIBLINGS of `data` at the event level
                // (backend a00de63); fold them into data so the dispatcher sees one shape.
                if (e["ack"] != null && data["ack"] == null) data["ack"] = e["ack"];
                if (e["ttlMs"] != null && data["ttlMs"] == null) data["ttlMs"] = e["ttlMs"];
                Events++;
                if (seq > _since) _since = seq;
                AowlApi.OnMain(() => AowlEvents.Dispatch(this, seq, kind, data));
            }
            if (n > 0) SaveCursor();
            State = "polling";
            return n >= Limit;
        }

        private void SaveCursor()
        {
            try { File.WriteAllText(_cursorFile, _since.ToString()); }
            catch (Exception ex) { if (AowlApi.Once("cursor-write")) AowlApi.Log.LogWarning("aowl.api link: cannot persist the cursor: " + ex.Message); }
        }

        // ------------------------------------------------------------ /observe and /ack

        /// <summary>POST /observe, fire and forget. Any thread. Silently dropped before the backend is Ready.</summary>
        public void Observe(string kind, JObject fields)
        {
            if (!AowlBackend.IsReady) return;
            var body = fields ?? new JObject();
            body["kind"] = kind;
            Observed++;
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            Task.Run(async () =>
            {
                var r = await AowlHttp.PostAsync(AowlHttp.Route("/observe"), text, 10000).ConfigureAwait(false);
                if (!r.Ok && AowlApi.Once("observe-fail:" + kind + ":" + r.Status))
                    AowlApi.Log.LogWarning("aowl.api observe(" + kind + ") answered " + r.Err + " -- said once per kind and status; nothing is retried.");
            });
        }

        /// <summary>POST /ack. Every directive exactly once; ok:false with a reason is a first-class answer.</summary>
        public void Ack(long seq, bool ok, string note)
        {
            Acks++;
            var body = new JObject { ["seq"] = seq, ["ok"] = ok, ["note"] = note ?? "" };
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            Task.Run(async () =>
            {
                var r = await AowlHttp.PostAsync(AowlHttp.Route("/ack"), text, 10000).ConfigureAwait(false);
                if (r.Error != null || r.Status != 200)
                {
                    if (AowlApi.Once("ack-fail:" + r.Status)) AowlApi.Log.LogWarning("aowl.api ack(" + seq + ") answered " + r.Err);
                }
                else if (r.Json != null && !(r.Json.Value<bool?>("ok") ?? false))
                {
                    AowlApi.Log.LogInfo("aowl.api ack(" + seq + ") was not pending: " + (r.Json.Value<string>("err") ?? ""));
                }
            });
        }
    }
}
