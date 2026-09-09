using System;
using System.Collections.Generic;
using Aowl.Api;
using Comfort.Common;
using DrakiaXYZ.BigBrain.Brains;
using EFT;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Basement.Client
{
    /// <summary>
    /// The npc.* actuator. SAIN 4.5.1 exposes NO order API (SAIN.Interop.SAINExternal is
    /// IgnoreHearing / GetPersonality / ExtractBot / TrySetExfilForBot / CanBotQuest /
    /// TimeSinceSenseEnemy / IsPathTowardEnemy -- measured, nothing that moves a bot), and
    /// its own layers re-issue movement every tick, so a bare BotOwner.Mover.GoToPoint
    /// is overwritten within a frame. The one sanctioned way to take a SAIN bot over is
    /// the same one SAIN itself uses: a DrakiaXYZ BigBrain CustomLayer registered at a
    /// higher priority than SAIN's (SAIN's PMC layers are 99 / 85 / 80, measured ldc.i4
    /// in BrainAssignment.AddCustomLayersToPMCs; MoreBotsAPI's HuntTargetLayer does the
    /// same). While an order exists for a bot the layer is active and SAIN's combat layers
    /// are simply lower; when the order is cleared SAIN resumes.
    ///
    /// Orders keyed by the bot's ProfileId; the backend's personId is resolved through
    /// People (nickname binding) or a live registry fed by BotsController.Bots.BotOwners.
    ///   npc.goto   {personId, x,y,z}         -> Mover.GoToPoint every tick until within 1.5 m
    ///   npc.hold   {personId}                -> Mover.Stop, stays put
    ///   npc.follow {personId, target}        -> GoToPoint(target) when farther than 6 m, else Stop
    ///   npc.attack {personId, target}        -> BotsGroup.AddEnemy(target, addPlayer), order cleared (SAIN fights)
    ///   npc.stance {personId, stance}        -> hostile: AddEnemy; neutral: RemoveEnemy+AddNeutral; friendly: AddAlly
    /// Nothing here has run live; docs/SPT415-BOT-CONTROL.md section 2d lists what is measured.
    /// </summary>
    internal static class Orders
    {
        internal const int LayerPriority = 120;
        public static int Accepted, Refused, Ticks;
        private static bool _layerRegistered;

        private sealed class Order { public string Kind; public Vector3 Point; public string TargetPersonId; public long Seq; public float IssuedAt; }
        private static readonly Dictionary<string, Order> ByProfile = new Dictionary<string, Order>();

        /// <summary>Brains the layer is attached to. "PMC" (raiders), "ExUsec", "ArenaFighter",
        /// "PmcBear", "PmcUsec" are measured literals in SAIN.BigBrainHandler; "Assault" (scavs)
        /// is the BigBrain convention and is NOT measured on this build.</summary>
        internal static readonly List<string> Brains = new List<string> { "PMC", "PmcBear", "PmcUsec", "ExUsec", "ArenaFighter", "Assault" };

        public static void Install()
        {
            AowlEvents.Directives.Register("npc.goto", e => { if (e.WantsAck) Handle(e); });
            AowlEvents.Directives.Register("npc.hold", e => { if (e.WantsAck) Handle(e); });
            AowlEvents.Directives.Register("npc.follow", e => { if (e.WantsAck) Handle(e); });
            AowlEvents.Directives.Register("npc.attack", e => { if (e.WantsAck) Handle(e); });
            AowlEvents.Directives.Register("npc.stance", e => { if (e.WantsAck) Handle(e); });
            try
            {
                BrainManager.AddCustomLayer(typeof(BasementLayer), Brains, LayerPriority);
                _layerRegistered = true;
                Plugin.Log.LogInfo("basement orders: BigBrain layer `Basement` registered at priority " + LayerPriority + " on brains " + string.Join(",", Brains) + ".");
            }
            catch (Exception ex)
            {
                Plugin.Log.LogError("basement orders: BigBrain layer NOT registered (" + ex.GetType().Name + ": " + ex.Message + ") -- every npc.goto/hold/follow will be acked ok:false.");
            }
        }

        public static bool Has(BotOwner bot)
        {
            if (bot == null) return false;
            lock (ByProfile) return ByProfile.ContainsKey(bot.ProfileId ?? "");
        }

        private static void Handle(AowlEvent e)
        {
            string why;
            try { why = Execute(e); }
            catch (Exception ex) { why = e.Kind + " threw " + ex.GetType().Name + ": " + ex.Message; }
            if (why == null) { Accepted++; e.Ack(true, "accepted"); }
            else { Refused++; Plugin.Log.LogWarning("basement " + e.Kind + " REFUSED: " + why); e.Ack(false, why); }
        }

        private static string Execute(AowlEvent e)
        {
            var personId = e.Str("personId");
            if (personId.Length == 0) return "no personId";
            var bot = BotOf(personId);
            if (bot == null) return "person `" + personId + "` is not bound to a live BotOwner (People.BotFor + BotsController.Bots.BotOwners both miss)";
            if (bot.BotState != EBotState.Active) return "bot `" + bot.ProfileId + "` is " + bot.BotState + ", not Active";
            var kind = e.Kind;
            switch (kind)
            {
                case "npc.goto":
                {
                    if (!_layerRegistered) return "BigBrain layer not registered";
                    var p = new Vector3(e.Data.Value<float?>("x") ?? 0f, e.Data.Value<float?>("y") ?? 0f, e.Data.Value<float?>("z") ?? 0f);
                    Set(bot, new Order { Kind = kind, Point = p, Seq = e.Seq, IssuedAt = Time.time });
                    return null;
                }
                case "npc.hold":
                    if (!_layerRegistered) return "BigBrain layer not registered";
                    Set(bot, new Order { Kind = kind, Seq = e.Seq, IssuedAt = Time.time });
                    return null;
                case "npc.follow":
                {
                    if (!_layerRegistered) return "BigBrain layer not registered";
                    var t = e.Str("target", "player");
                    if (TargetOf(t) == null) return "follow target `" + t + "` is not a live player";
                    Set(bot, new Order { Kind = kind, TargetPersonId = t, Seq = e.Seq, IssuedAt = Time.time });
                    return null;
                }
                case "npc.attack":
                {
                    var t = e.Str("target", "player");
                    var target = TargetOf(t);
                    if (target == null) return "attack target `" + t + "` is not a live player";
                    var g = bot.BotsGroup;
                    if (g == null) return "bot has no BotsGroup";
                    var added = g.AddEnemy(target, EBotEnemyCause.addPlayer);
                    Clear(bot);
                    Plugin.Log.LogInfo("basement npc.attack: " + bot.Profile?.Info?.Nickname + " -> " + t + " AddEnemy=" + added + " (SAIN's combat layer takes it from here).");
                    return added || g.IsEnemy(target) ? null : "BotsGroup.AddEnemy returned false and the target is still not an enemy";
                }
                case "npc.stance":
                {
                    var g = bot.BotsGroup;
                    if (g == null) return "bot has no BotsGroup";
                    var stance = e.Str("stance", "neutral");
                    var target = TargetOf(e.Str("target", "player"));
                    if (target == null) return "stance target is not a live player";
                    switch (stance)
                    {
                        case "hostile": g.AddEnemy(target, EBotEnemyCause.addPlayer); break;
                        case "neutral": g.RemoveEnemy(target, EBotEnemyCause.addPlayer); g.AddNeutral(target); break;
                        case "friendly":
                            var pl = target as Player;
                            if (pl == null) return "friendly needs an EFT.Player target (AddAlly takes Player)";
                            g.RemoveEnemy(target, EBotEnemyCause.addPlayer); g.AddAlly(pl); break;
                        default: return "stance `" + stance + "` is not hostile|neutral|friendly";
                    }
                    var stillEnemy = g.IsEnemy(target);
                    if (stance == "hostile" && !stillEnemy) return "after AddEnemy the target is still not an enemy";
                    if (stance != "hostile" && stillEnemy) return "after RemoveEnemy the target is still an enemy";
                    return null;
                }
            }
            return "unhandled kind " + kind;
        }

        private static void Set(BotOwner bot, Order o) { lock (ByProfile) ByProfile[bot.ProfileId] = o; }
        private static void Clear(BotOwner bot) { lock (ByProfile) ByProfile.Remove(bot.ProfileId ?? ""); }
        private static Order Get(BotOwner bot) { lock (ByProfile) { Order o; return ByProfile.TryGetValue(bot.ProfileId ?? "", out o) ? o : null; } }

        /// <summary>"player" = the main player; otherwise a backend personId bound to a bot.</summary>
        private static IPlayer TargetOf(string target)
        {
            if (target == "player")
            {
                var gw = Singleton<GameWorld>.Instantiated ? Singleton<GameWorld>.Instance : null;
                // Player implements IDissonancePlayer; the implicit Player->IPlayer conversion makes the
                // compiler demand DissonanceVoip.dll. Going through object keeps that assembly out of the build.
                object mp = gw?.MainPlayer;
                return mp as IPlayer;
            }
            object bot = People.BotFor(target);
            return bot as IPlayer;
        }

        private static BotOwner BotOf(string personId)
        {
            var player = People.BotFor(personId);
            var bo = player?.AIData?.BotOwner;
            if (bo != null) return bo;
            // Fallback: the live list, matched by nickname == person name (the server mod wrote it).
            var name = People.NameOf(personId);
            if (!Singleton<IBotGame>.Instantiated) return null;
            var bots = Singleton<IBotGame>.Instance?.BotsController?.Bots?.BotOwners;
            if (bots == null) return null;
            foreach (var b in bots)
            {
                if (b?.Profile?.Info?.Nickname == name) { People.Bind(personId, b.GetPlayer, "orders/nickname"); return b; }
            }
            return null;
        }

        // ------------------------------------------------------------ the BigBrain layer

        /// <summary>Active exactly while an order exists for this bot.</summary>
        internal sealed class BasementLayer : CustomLayer
        {
            public BasementLayer(BotOwner botOwner, int priority) : base(botOwner, priority) { }
            public override string GetName() => "Basement";
            public override bool IsActive() => Orders.Has(BotOwner);
            public override Action GetNextAction() => new Action(typeof(BasementLogic), "basement order");
            public override bool IsCurrentActionEnding() => !Orders.Has(BotOwner);
        }

        internal sealed class BasementLogic : CustomLogic
        {
            private float _nextMove;
            public BasementLogic(BotOwner botOwner) : base(botOwner) { }
            public override void Start() { _nextMove = 0f; }
            public override void Stop() { }
            public override void Update(CustomLayer.ActionData data)
            {
                Ticks++;
                var o = Orders.Get(BotOwner);
                if (o == null) return;
                var mover = BotOwner.Mover;
                if (mover == null) return;
                switch (o.Kind)
                {
                    case "npc.hold":
                        if (Time.time >= _nextMove) { mover.Stop(); _nextMove = Time.time + 1f; }
                        return;
                    case "npc.goto":
                        if ((BotOwner.Position - o.Point).sqrMagnitude < 2.25f) { mover.Stop(); Orders.Clear(BotOwner); Plugin.Log.LogInfo("basement npc.goto seq " + o.Seq + ": arrived."); return; }
                        if (Time.time >= _nextMove)
                        {
                            // BotMover.GoToPoint(Vector3 pos, bool slowAtTheEnd, float reachDist, bool getUpWithCheck, bool mustHaveWay, bool onlyShortTrie, bool force) -- measured.
                            var st = mover.GoToPoint(o.Point, true, 1.0f, false, true, false, false);
                            _nextMove = Time.time + 1f;
                            if (st == UnityEngine.AI.NavMeshPathStatus.PathInvalid) { Plugin.Log.LogWarning("basement npc.goto seq " + o.Seq + ": PathInvalid to " + o.Point + " -- order cleared."); Orders.Clear(BotOwner); }
                        }
                        return;
                    case "npc.follow":
                    {
                        var t = Orders.TargetOf(o.TargetPersonId);
                        if (t == null) { Orders.Clear(BotOwner); return; }
                        var tp = t.Position;
                        var d2 = (BotOwner.Position - tp).sqrMagnitude;
                        if (d2 > 36f) { if (Time.time >= _nextMove) { mover.GoToPoint(tp, true, 3.0f, false, true, false, false); _nextMove = Time.time + 0.5f; } }
                        else if (d2 < 9f && Time.time >= _nextMove) { mover.Stop(); _nextMove = Time.time + 0.5f; }
                        return;
                    }
                }
            }
        }
    }
}
