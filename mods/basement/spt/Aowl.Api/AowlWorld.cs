using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>One backend person (GET /world/people, /world/person/&lt;id&gt;, /world/scene).</summary>
    public sealed class PersonInfo
    {
        /// <summary>Opaque id; the key for Ask, say events and facts.</summary>
        public string Id;
        /// <summary>Display name.</summary>
        public string Name;
        /// <summary>Faction id.</summary>
        public string Faction;
        /// <summary>Role within the faction.</summary>
        public string Role;
        /// <summary>The voice name the backend speaks this person with.</summary>
        public string Voice;
        /// <summary>The map the world places this person on (the world's own fiction; a live bot may be elsewhere).</summary>
        public string Map;
        /// <summary>The named place on that map.</summary>
        public string Place;
        /// <summary>World position.</summary>
        public float X, Y, Z;
        /// <summary>What the person is doing.</summary>
        public string Activity;
        /// <summary>False once the world recorded the death.</summary>
        public bool Alive;
        /// <summary>Health 0..1 in the world's own accounting.</summary>
        public float Hp;
        /// <summary>Mood -1..1.</summary>
        public float Mood;
        /// <summary>Attitude toward the player.</summary>
        public string Attitude;
        /// <summary>The group id.</summary>
        public string Group;
        /// <summary>True while escorting the player.</summary>
        public bool Escorting;
        /// <summary>The encounter machine's state for this person ("" when none).</summary>
        public string EncounterState;
        /// <summary>The raw object, for traits/memory/knows/inventoryNote.</summary>
        public JObject Raw;

        internal static PersonInfo From(JObject o)
        {
            if (o == null) return null;
            var id = o.Value<string>("id");
            if (string.IsNullOrEmpty(id)) return null;
            return new PersonInfo
            {
                Id = id, Name = o.Value<string>("name") ?? id,
                // The backend writes `faction` (bm/world.nim personJson); `factionId` is the contract's older spelling.
                Faction = o.Value<string>("faction") ?? o.Value<string>("factionId") ?? "",
                Role = o.Value<string>("role") ?? "", Voice = o.Value<string>("voice") ?? "", Map = o.Value<string>("map") ?? "", Place = o.Value<string>("place") ?? "",
                X = o.Value<float?>("x") ?? 0, Y = o.Value<float?>("y") ?? 0, Z = o.Value<float?>("z") ?? 0,
                Activity = o.Value<string>("activity") ?? "", Alive = o.Value<bool?>("alive") ?? true, Hp = o.Value<float?>("hp") ?? 1f, Mood = o.Value<float?>("mood") ?? 0f,
                Attitude = o.Value<string>("attitude") ?? "", Group = o.Value<string>("group") ?? "", Escorting = o.Value<bool?>("escorting") ?? false,
                EncounterState = o.Value<string>("encounterState") ?? "", Raw = o,
            };
        }

        /// <summary>Squared distance to a point, in the world's coordinates.</summary>
        public float DistanceSqTo(float x, float y, float z) { float dx = X - x, dy = Y - y, dz = Z - z; return dx * dx + dy * dy + dz * dz; }
    }

    /// <summary>One cache (GET /world/caches, /world/scene).</summary>
    public sealed class CacheInfo
    {
        /// <summary>Id, name, place, map, owner, guard group, story, status ("rumoured" / "intact" / ...), who planted it.</summary>
        public string Id, Name, Place, Map, Owner, GuardGroup, Story, Status, PlantedBy;
        /// <summary>World position.</summary>
        public float X, Y, Z;
        /// <summary>Items as (tpl, count).</summary>
        public List<KeyValuePair<string, int>> Items = new List<KeyValuePair<string, int>>();
        /// <summary>The raw object (pickups, createdMs...).</summary>
        public JObject Raw;

        internal static CacheInfo From(JObject o)
        {
            if (o == null) return null;
            var c = new CacheInfo
            {
                Id = o.Value<string>("id") ?? "", Name = o.Value<string>("name") ?? "", Place = o.Value<string>("place") ?? "", Map = o.Value<string>("map") ?? "",
                Owner = o.Value<string>("owner") ?? "", GuardGroup = o.Value<string>("guardGroup") ?? "", Story = o.Value<string>("story") ?? "", Status = o.Value<string>("status") ?? "",
                PlantedBy = o.Value<string>("plantedBy") ?? "", X = o.Value<float?>("x") ?? 0, Y = o.Value<float?>("y") ?? 0, Z = o.Value<float?>("z") ?? 0, Raw = o,
            };
            if (o["items"] is JArray items)
                foreach (var t in items)
                    if (t is JObject it) c.Items.Add(new KeyValuePair<string, int>(it.Value<string>("tpl") ?? "", it.Value<int?>("count") ?? 1));
            return c;
        }
    }

    /// <summary>One loot row (GET /world/loot, /world/scene).</summary>
    public sealed class LootInfo
    {
        /// <summary>Id, the cache it came from, the item template, the map, its status ("placed" / ...).</summary>
        public string Id, CacheId, Tpl, Map, Status;
        /// <summary>Count.</summary>
        public int Count;
        /// <summary>World position.</summary>
        public float X, Y, Z;
        /// <summary>The raw object.</summary>
        public JObject Raw;

        internal static LootInfo From(JObject o)
        {
            if (o == null) return null;
            return new LootInfo
            {
                Id = o.Value<string>("id") ?? "", CacheId = o.Value<string>("cacheId") ?? "", Tpl = o.Value<string>("tpl") ?? "", Map = o.Value<string>("map") ?? "",
                Status = o.Value<string>("status") ?? "", Count = o.Value<int?>("count") ?? 1, X = o.Value<float?>("x") ?? 0, Y = o.Value<float?>("y") ?? 0, Z = o.Value<float?>("z") ?? 0, Raw = o,
            };
        }
    }

    /// <summary>What must exist around a point (GET /world/scene). Calling it MATERIALISES rumoured caches.</summary>
    public sealed class SceneInfo
    {
        /// <summary>People near the point.</summary>
        public List<PersonInfo> People = new List<PersonInfo>();
        /// <summary>Caches near the point (rumoured ones become intact).</summary>
        public List<CacheInfo> Caches = new List<CacheInfo>();
        /// <summary>Loot rows the caches materialised into.</summary>
        public List<LootInfo> Loot = new List<LootInfo>();
        /// <summary>The raw answer (groups and anything not lifted).</summary>
        public JObject Raw;
    }

    /// <summary>Where the world wants the player next (GET /spawn).</summary>
    public sealed class SpawnPlace
    {
        /// <summary>The map ("" when the world has nowhere to put the player -- see Err).</summary>
        public string Map;
        /// <summary>Position on it.</summary>
        public float X, Y, Z;
        /// <summary>Why there.</summary>
        public string Reason;
        /// <summary>True when the backend itself will request the raid (its autoRaid setting).</summary>
        public bool RaidRequested;
        /// <summary>The backend's refusal when Map is "".</summary>
        public string Err;
        /// <summary>The raw answer.</summary>
        public JObject Raw;
    }

    /// <summary>A typed query result: either the value or the reason it could not be had.</summary>
    public sealed class Result<T>
    {
        /// <summary>The value (null on failure).</summary>
        public T Value;
        /// <summary>The refusal / transport error (null on success).</summary>
        public string Error;
        /// <summary>True when Value is valid.</summary>
        public bool Ok => Error == null;
        internal static Result<T> Fail(string why) => new Result<T> { Error = why ?? "failed" };
        internal static Result<T> Of(T v) => new Result<T> { Value = v };
    }

    /// <summary>
    /// Typed queries of the backend world. Every method has a synchronous form
    /// (BACKGROUND threads only) and an Async form (any thread). Nothing here
    /// is cached: the backend answers in milliseconds and the population moves.
    /// </summary>
    public static class AowlWorld
    {
        private static string F(float v) => v.ToString("0.##", CultureInfo.InvariantCulture);

        /// <summary>GET /world/people[?map=&amp;near=x,y,z&amp;radius=]. Background thread. Empty map = every map. `near` without radius uses the backend's noticeM.</summary>
        public static Result<List<PersonInfo>> People(string map = null, float? nearX = null, float? nearY = null, float? nearZ = null, float radius = 0)
            => PeopleAsync(map, nearX, nearY, nearZ, radius).GetAwaiter().GetResult();

        /// <summary>See <see cref="People"/>. Any thread.</summary>
        public static async Task<Result<List<PersonInfo>>> PeopleAsync(string map = null, float? nearX = null, float? nearY = null, float? nearZ = null, float radius = 0)
        {
            var url = AowlHttp.Route("/world/people");
            var q = new List<string>();
            if (!string.IsNullOrEmpty(map)) q.Add("map=" + Uri.EscapeDataString(map));
            // The backend parses `near` as INTEGERS (basement.nim onPeople); fractions are dropped there, so send whole numbers.
            if (nearX.HasValue && nearY.HasValue && nearZ.HasValue) q.Add("near=" + (int)nearX.Value + "," + (int)nearY.Value + "," + (int)nearZ.Value);
            if (radius > 0) q.Add("radius=" + ((int)radius));
            if (q.Count > 0) url += "?" + string.Join("&", q);
            var r = await AowlHttp.GetAsync(url, 10000).ConfigureAwait(false);
            if (!r.Ok) return Result<List<PersonInfo>>.Fail("GET /world/people answered " + r.Err);
            var list = new List<PersonInfo>();
            if (r.Json["people"] is JArray arr)
                foreach (var t in arr) { var p = PersonInfo.From(t as JObject); if (p != null) list.Add(p); }
            return Result<List<PersonInfo>>.Of(list);
        }

        /// <summary>GET /world/person/&lt;id&gt;. Background thread.</summary>
        public static Result<PersonInfo> Person(string id) => PersonAsync(id).GetAwaiter().GetResult();

        /// <summary>See <see cref="Person"/>. Any thread.</summary>
        public static async Task<Result<PersonInfo>> PersonAsync(string id)
        {
            if (string.IsNullOrEmpty(id)) return Result<PersonInfo>.Fail("empty person id");
            var r = await AowlHttp.GetAsync(AowlHttp.Route("/world/person/" + Uri.EscapeDataString(id)), 10000).ConfigureAwait(false);
            if (!r.Ok) return Result<PersonInfo>.Fail("GET /world/person/" + id + " answered " + r.Err);
            var p = PersonInfo.From(r.Json["person"] as JObject ?? r.Json);
            return p != null ? Result<PersonInfo>.Of(p) : Result<PersonInfo>.Fail("the answer carried no person object");
        }

        /// <summary>GET /world/scene?map=&amp;x=&amp;y=&amp;z=&amp;radius=. Background thread. MATERIALISES: rumoured caches near the point become intact and their items loot rows.</summary>
        public static Result<SceneInfo> Scene(string map, float x, float y, float z, float radius = 0) => SceneAsync(map, x, y, z, radius).GetAwaiter().GetResult();

        /// <summary>See <see cref="Scene"/>. Any thread.</summary>
        public static async Task<Result<SceneInfo>> SceneAsync(string map, float x, float y, float z, float radius = 0)
        {
            if (string.IsNullOrEmpty(map)) return Result<SceneInfo>.Fail("no map");
            var url = AowlHttp.Route("/world/scene") + "?map=" + Uri.EscapeDataString(map) + "&x=" + F(x) + "&y=" + F(y) + "&z=" + F(z) + (radius > 0 ? "&radius=" + F(radius) : "");
            var r = await AowlHttp.GetAsync(url, 15000).ConfigureAwait(false);
            if (!r.Ok) return Result<SceneInfo>.Fail("GET /world/scene answered " + r.Err);
            var s = new SceneInfo { Raw = r.Json };
            if (r.Json["people"] is JArray pa) foreach (var t in pa) { var p = PersonInfo.From(t as JObject); if (p != null) s.People.Add(p); }
            if (r.Json["caches"] is JArray ca) foreach (var t in ca) { var c = CacheInfo.From(t as JObject); if (c != null) s.Caches.Add(c); }
            if (r.Json["loot"] is JArray la) foreach (var t in la) { var l = LootInfo.From(t as JObject); if (l != null) s.Loot.Add(l); }
            return Result<SceneInfo>.Of(s);
        }

        /// <summary>GET /world/loot?map=. Background thread.</summary>
        public static Result<List<LootInfo>> Loot(string map) => LootAsync(map).GetAwaiter().GetResult();

        /// <summary>See <see cref="Loot"/>. Any thread.</summary>
        public static async Task<Result<List<LootInfo>>> LootAsync(string map)
        {
            var r = await AowlHttp.GetAsync(AowlHttp.Route("/world/loot") + "?map=" + Uri.EscapeDataString(map ?? ""), 10000).ConfigureAwait(false);
            if (!r.Ok) return Result<List<LootInfo>>.Fail("GET /world/loot answered " + r.Err);
            var list = new List<LootInfo>();
            if (r.Json["loot"] is JArray arr) foreach (var t in arr) { var l = LootInfo.From(t as JObject); if (l != null) list.Add(l); }
            return Result<List<LootInfo>>.Of(list);
        }

        /// <summary>GET /world/caches?map=. Background thread.</summary>
        public static Result<List<CacheInfo>> Caches(string map) => CachesAsync(map).GetAwaiter().GetResult();

        /// <summary>See <see cref="Caches"/>. Any thread.</summary>
        public static async Task<Result<List<CacheInfo>>> CachesAsync(string map)
        {
            var r = await AowlHttp.GetAsync(AowlHttp.Route("/world/caches") + "?map=" + Uri.EscapeDataString(map ?? ""), 10000).ConfigureAwait(false);
            if (!r.Ok) return Result<List<CacheInfo>>.Fail("GET /world/caches answered " + r.Err);
            var list = new List<CacheInfo>();
            if (r.Json["caches"] is JArray arr) foreach (var t in arr) { var c = CacheInfo.From(t as JObject); if (c != null) list.Add(c); }
            return Result<List<CacheInfo>>.Of(list);
        }

        /// <summary>GET /spawn: where the world wants the player next. Background thread. A declined placement is Ok with Map "" and Err set.</summary>
        public static Result<SpawnPlace> Spawn() => SpawnAsync().GetAwaiter().GetResult();

        /// <summary>See <see cref="Spawn"/>. Any thread.</summary>
        public static async Task<Result<SpawnPlace>> SpawnAsync()
        {
            var r = await AowlHttp.GetAsync(AowlHttp.Route("/spawn"), 10000).ConfigureAwait(false);
            if (r.Error != null || r.Status != 200 || r.Json == null) return Result<SpawnPlace>.Fail("GET /spawn answered " + r.Err);
            // The map sits under `spawn` (MEASURED: basement.nim onSpawn puts {map,x,y,z,reason} in `spawn`).
            var sp = r.Json["spawn"] as JObject ?? r.Json;
            var s = new SpawnPlace
            {
                Map = sp.Value<string>("map") ?? "", X = sp.Value<float?>("x") ?? 0, Y = sp.Value<float?>("y") ?? 0, Z = sp.Value<float?>("z") ?? 0,
                Reason = sp.Value<string>("reason") ?? "", RaidRequested = r.Json.Value<bool?>("raidRequested") ?? false, Raw = r.Json,
            };
            if (!(r.Json.Value<bool?>("ok") ?? false) || s.Map.Length == 0) { s.Map = ""; s.Err = r.Json.Value<string>("err") ?? "the backend answered ok:false with no map"; }
            return Result<SpawnPlace>.Of(s);
        }

        /// <summary>GET /world: the world summary (name, day, counts, captiveOf, note). Background thread. Error when there is no world yet.</summary>
        public static Result<JObject> World() { var r = AowlHttp.Get(AowlHttp.Route("/world"), 5000); return r.Ok ? Result<JObject>.Of(r.Json) : Result<JObject>.Fail("GET /world answered " + r.Err); }

        /// <summary>The nearest alive person to a point among <paramref name="people"/>, or null.</summary>
        public static PersonInfo Nearest(List<PersonInfo> people, float x, float y, float z, bool aliveOnly = true)
        {
            PersonInfo best = null; float bd = float.MaxValue;
            if (people == null) return null;
            foreach (var p in people)
            {
                if (aliveOnly && !p.Alive) continue;
                float d = p.DistanceSqTo(x, y, z);
                if (d < bd) { bd = d; best = p; }
            }
            return best;
        }
    }
}
