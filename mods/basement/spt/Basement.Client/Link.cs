using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using BepInEx;
using Newtonsoft.Json.Linq;

namespace Basement.Client
{
    /// <summary>
    /// The long poll, the dispatch and the ack -- a mirror of
    /// mods/basement/bridge/link.nim.
    ///
    /// ONE REQUEST IN FLIGHT AT A TIME: the loop is a single thread, so two
    /// overlapping polls with the same `since` (which would execute every
    /// directive twice) cannot happen by construction.
    ///
    /// THE CURSOR advances only to seqs we actually parsed and is persisted to
    /// BepInEx/config/aowl.basement.cursor so a restart does not replay old
    /// directives. `firstSeq` is the hole detector (CLIENT-CONTRACT section 4):
    /// a cursor older than firstSeq-1 means PROVABLY missed events, announced
    /// loudly and resynced to latestSeq, never resumed silently.
    ///
    /// DISPATCH IS BY KIND and an unknown directive is ACKED ok:false with
    /// "unsupported kind", never ignored. Every directive is acked exactly once.
    /// </summary>
    internal sealed class Link
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

        public long Cursor => _since;
        public long LatestSeq => _latest;
        public long FirstSeq => _first;
        public int Polls, Batches, Events, Directives, Unsupported, Holes, Observed, Acks;
        public volatile string State = "idle";
        public volatile string LastError = "";

        public void Start()
        {
            if (_running) return;
            // Fully qualified: Assembly-CSharp declares a global `Paths` type that shadows BepInEx.Paths (measured at compile).
            _cursorFile = Path.Combine(BepInEx.Paths.ConfigPath, "aowl.basement.cursor");
            try
            {
                if (File.Exists(_cursorFile) && long.TryParse(File.ReadAllText(_cursorFile).Trim(), out var c) && c > 0)
                {
                    _since = c;
                    _haveCursor = true;
                }
            }
            catch (Exception ex) { Plugin.Log.LogWarning("basement link: cursor file unreadable: " + ex.Message); }
            _running = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "basement-link" };
            _thread.Start();
        }

        public void Stop() { _running = false; }

        private void Loop()
        {
            // No stored cursor: probe with wait=0 and start at latestSeq rather than
            // replaying whatever the ring holds from before this client existed.
            if (!_haveCursor)
            {
                var probe = Http.Get(Http.Route("/events") + "?since=0&wait=0&limit=1", 10000);
                if (probe.Ok)
                {
                    _since = probe.Json.Value<long?>("latestSeq") ?? 0;
                    _haveCursor = true;
                    Plugin.Log.LogInfo("basement link: no stored cursor; starting at latestSeq " + _since + " (the ring history is NOT replayed).");
                    SaveCursor();
                }
            }
            bool immediate = false;
            while (_running)
            {
                int wait = immediate ? 0 : Math.Max(0, Math.Min(25000, Plugin.PollWaitMs.Value));
                var url = Http.Route("/events") + "?since=" + _since + "&wait=" + wait + "&limit=" + Limit;
                Polls++;
                var r = Http.Get(url, wait + 10000);
                if (!_running) break;
                if (r.Error != null || r.Status != 200 || r.Json == null)
                {
                    State = "poll failed";
                    LastError = r.Err;
                    if (Plugin.Once("poll-fail:" + r.Status + ":" + r.Error))
                        Plugin.Log.LogWarning("basement link: the long poll failed -- HTTP " + r.Status +
                            (r.Error != null ? ", transport: " + r.Error : "") + ". Cursor unchanged (" + _since +
                            "), retrying every " + RetryMs + " ms. Said once per status.");
                    immediate = false;
                    // A TRANSPORT failure (HTTP 0) three polls running means the
                    // sidecar is gone, not busy. MEASURED 2026-09-07: the backend
                    // died on an AssertionDefect mid-raid and every request failed
                    // for the rest of the raid. Sidecar.Ensure() is idempotent: it
                    // returns at once when /status answers or another backend
                    // process exists, so this cannot start a second one.
                    if (r.Error != null && r.Status == 0) _transportFails++; else _transportFails = 0;
                    if (_transportFails == 3 && Plugin.SidecarAutoStart.Value)
                    {
                        Plugin.Log.LogWarning("basement link: 3 transport failures in a row -- asking Sidecar.Ensure() to restart the backend.");
                        try { Sidecar.Ensure(); } catch (Exception ex) { Plugin.Log.LogWarning("basement link: Sidecar.Ensure threw " + ex.Message); }
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
                if (Plugin.Once("events-notok")) Plugin.Log.LogWarning("basement link: GET /events did not answer ok:true: " + o.ToString(Newtonsoft.Json.Formatting.None));
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
                Plugin.Log.LogWarning("basement link: the backend restarted -- cursor " + _since + " is past its latestSeq " +
                    _latest + ". Rewinding to " + Math.Max(0, _first - 1) + " and replaying the new ring.");
                _since = Math.Max(0, _first - 1);
                SaveCursor();
                State = "rewound after a backend restart";
                People.RefreshSync(null);
                return true;
            }
            if (_since > 0 && _first > 0 && _since < _first - 1)
            {
                Holes++;
                Plugin.Log.LogWarning("basement link: PROVABLY MISSED EVENTS -- cursor " + _since + ", ring starts at " + _first +
                    ". Resyncing to " + _latest + " and re-reading /world/people; everything between is gone.");
                _since = _latest;
                SaveCursor();
                State = "resynced after a hole";
                People.RefreshSync(null);
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
                Plugin.OnMain(() => Dispatch(seq, kind, data));
            }
            if (n > 0) SaveCursor();
            State = "polling";
            return n >= Limit;
        }

        private void SaveCursor()
        {
            try { File.WriteAllText(_cursorFile, _since.ToString()); }
            catch (Exception ex) { if (Plugin.Once("cursor-write")) Plugin.Log.LogWarning("basement link: cannot persist the cursor: " + ex.Message); }
        }

        // ------------------------------------------------------------ dispatch (main thread)

        private void Dispatch(long seq, string kind, JObject data)
        {
            // MEASURED 2026-09-07: the backend's event JSON carried no `ack` field at
            // all, so every directive was silently "passive" here and dropped after
            // ttl on the other side. Until the backend writes it, a directive kind
            // (anything not in the passive set below) wants an ack.
            // The flag is a SIBLING of `data` at the event level (backend commit
            // a00de63 writes {seq, atMs, kind, ack, ttlMs, data}); the data-level
            // read is kept for any older backend.
            bool? ackField = data.Value<bool?>("ack");
            bool wantsAck = ackField ?? !(kind == "say" || kind.StartsWith("heard.") || kind == "hud.note" ||
                                          kind == "world.saved" || kind.StartsWith("directive.") || kind.StartsWith("quest."));
            if (wantsAck) Directives++;
            switch (kind)
            {
                case "say":
                    Say.Enqueue(data.Value<string>("personId") ?? "", seq, data.Value<int?>("segmentIdx") ?? 0,
                        data.Value<string>("wav") ?? "", data.Value<string>("text") ?? "",
                        data.Value<bool?>("final") ?? false, wantsAck);
                    return;
                case "heard.partial":
                    Hud.Note("(hearing) " + (data.Value<string>("text") ?? ""), 3f);
                    return;
                case "heard.final":
                {
                    var text = data.Value<string>("text") ?? "";
                    var note = data.Value<string>("note") ?? "";
                    // An empty final is "not transcribed", never "the player said nothing".
                    if (text.Length == 0) Hud.Warn("heard nothing transcribable" + (note.Length > 0 ? " -- " + note : ""));
                    else Hud.Note("you: " + text);
                    Plugin.Log.LogInfo("basement heard.final: \"" + text + "\" " + note);
                    return;
                }
                case "hud.note":
                {
                    var text = data.Value<string>("text") ?? "";
                    if ((data.Value<string>("severity") ?? "info") == "warn") { Hud.Warn(text); Plugin.Log.LogWarning("basement HUD: " + text); }
                    else { Hud.Note(text); Plugin.Log.LogInfo("basement HUD: " + text); }
                    return;
                }
                case "quest.offer":
                    Hud.Note("QUEST: " + (data.Value<string>("title") ?? "") + " -- " + (data.Value<string>("brief") ?? ""), 10f);
                    Plugin.Log.LogInfo("basement quest.offer: " + data.ToString(Newtonsoft.Json.Formatting.None));
                    return;
                case "quest.update":
                case "world.saved":
                    Plugin.Log.LogInfo("basement " + kind + ": " + data.ToString(Newtonsoft.Json.Formatting.None));
                    return;
                case "directive.acked":
                    return;
                case "directive.dropped":
                    Plugin.Log.LogWarning("basement link: the backend DROPPED directive seq " + data.Value<long?>("seq") + " (" +
                        data.Value<string>("kind") + ") -- " + (data.Value<string>("reason") ?? "no reason") +
                        ". That is a bug in THIS client: an unacked directive means the world proceeded as though the thing did not happen.");
                    return;
                case "player.spawn":
                    if (!wantsAck) return;
                    Spawn.OnDirective(seq, data);
                    return;
            }
            if (!wantsAck)
            {
                if (Plugin.Once("unknown-passive:" + kind))
                    Plugin.Log.LogInfo("basement link: event kind `" + kind + "` is not handled by this client and carries no ack. Ignored, said once.");
                return;
            }
            Unsupported++;
            string why = "unsupported kind";
            switch (kind)
            {
                case "npc.stance": case "npc.follow": case "npc.hold": case "npc.goto": case "npc.attack":
                    why = "unsupported kind: Basement.Client 0.1.0 has NO bot actuator (BotOwner.Mover/Memory orders are not wired yet).";
                    break;
                case "npc.give": case "npc.take": case "player.captive": case "player.release":
                    why = "unsupported kind: inventory and captivity are not wired in Basement.Client 0.1.0.";
                    break;
                case "group.spawn":
                    why = "unsupported kind: Basement.Client 0.1.0 does not drive SPT's BotSpawner; people are mapped to live bots by nickname instead (MatchPeopleByName).";
                    break;
            }
            if (Plugin.Once("unsupported:" + kind))
                Plugin.Log.LogWarning("basement link: refusing directive kind `" + kind + "` -- " + why + " ACKED ok:false, never ignored.");
            Ack(seq, false, why);
        }

        // ------------------------------------------------------------ /observe and /ack

        /// <summary>POST /observe, fire and forget. Any thread.</summary>
        public void Observe(string kind, JObject fields)
        {
            if (!Plugin.Started) return;
            var body = fields ?? new JObject();
            body["kind"] = kind;
            Observed++;
            var text = body.ToString(Newtonsoft.Json.Formatting.None);
            Task.Run(async () =>
            {
                var r = await Http.PostAsync(Http.Route("/observe"), text, 10000).ConfigureAwait(false);
                if (!r.Ok && Plugin.Once("observe-fail:" + kind + ":" + r.Status))
                    Plugin.Log.LogWarning("basement observe(" + kind + ") answered " + r.Err + " -- said once per kind and status; nothing is retried.");
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
                var r = await Http.PostAsync(Http.Route("/ack"), text, 10000).ConfigureAwait(false);
                if (r.Error != null || r.Status != 200)
                {
                    if (Plugin.Once("ack-fail:" + r.Status)) Plugin.Log.LogWarning("basement ack(" + seq + ") answered " + r.Err);
                }
                else if (r.Json != null && !(r.Json.Value<bool?>("ok") ?? false))
                {
                    Plugin.Log.LogInfo("basement ack(" + seq + ") was not pending: " + (r.Json.Value<string>("err") ?? ""));
                }
            });
        }
    }
}
