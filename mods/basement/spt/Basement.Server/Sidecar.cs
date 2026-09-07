using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SPTarkov.Common.Models.Logging;
using SPTarkov.DI.Annotations;

namespace Basement.Server;

// ---------------------------------------------------------------- wire shapes
// These mirror the emulator's bus payloads in mods/tarkov/emu/planting.nim
// (tarkov.bots.compose -> {map, raidId, wave, requested}; tarkov.bots.plant ->
// {raidId, groups:[{groupId, factionId, role, count, names}]}) so ONE backend
// route family serves both. Extra fields (side, difficulty, loadout, personIds)
// are additive; a backend that omits them changes nothing.

public sealed class BotsRequest
{
    [JsonPropertyName("map")] public string Map { get; set; } = "";
    [JsonPropertyName("raidId")] public string RaidId { get; set; } = "";
    [JsonPropertyName("wave")] public int Wave { get; set; }
    [JsonPropertyName("requested")] public List<RequestedRole> Requested { get; set; } = new();
}
public sealed class RequestedRole
{
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("limit")] public int Limit { get; set; }
    [JsonPropertyName("difficulty")] public string Difficulty { get; set; } = "";
}
public sealed class BotsResponse
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("note")] public string? Note { get; set; }
    /// <summary>Optional count/difficulty overrides for roles the CLIENT asked for. Roles it did not
    /// ask for are refused: the client only accepts profiles of the role it requested.</summary>
    [JsonPropertyName("limits")] public List<RequestedRole>? Limits { get; set; }
    [JsonPropertyName("groups")] public List<PlannedGroup>? Groups { get; set; }
}
public sealed class PlannedGroup
{
    [JsonPropertyName("groupId")] public string GroupId { get; set; } = "";
    [JsonPropertyName("factionId")] public string FactionId { get; set; } = "";
    [JsonPropertyName("role")] public string Role { get; set; } = "assault";
    [JsonPropertyName("count")] public int Count { get; set; }
    [JsonPropertyName("names")] public List<string> Names { get; set; } = new();
    [JsonPropertyName("personIds")] public List<string>? PersonIds { get; set; }
    /// <summary>A bot-db role whose TEMPLATE drives SPT's own inventory generator for these bots
    /// ("pmcBEAR", "exUsec", "bossKilla"...). Never an item tree.</summary>
    [JsonPropertyName("loadout")] public string? Loadout { get; set; }
    [JsonPropertyName("side")] public string? Side { get; set; }
    [JsonPropertyName("difficulty")] public string? Difficulty { get; set; }
}
public sealed class WavesResponse
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("note")] public string? Note { get; set; }
    [JsonPropertyName("clear")] public bool Clear { get; set; }
    /// <summary>EFT-native wave rows (the shape of locations/[map]/base.json waves[]), kept as raw
    /// JSON and parsed by SPT's own JsonUtil so the property names are SPT's, not ours.</summary>
    [JsonPropertyName("waves")] public JsonElement? Waves { get; set; }
    [JsonPropertyName("bossWaves")] public JsonElement? BossWaves { get; set; }
}

/// <summary>The one HTTP client to aowlspt-backend.exe. Every failure is a measured
/// string on the log and a null return: the patches then leave SPT's own output
/// untouched. Nothing here is ever silent.</summary>
[Injectable(InjectionType = InjectionType.Singleton)]
public sealed class Sidecar
{
    private readonly ISptLogger<Sidecar> _log;
    private readonly HttpClient _http = new();
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    public Config Cfg { get; set; } = new();
    public int Calls, Failures;
    public string LastError = "";

    public Sidecar(ISptLogger<Sidecar> log) { _log = log; }

    private string Route(string path) => Cfg.SidecarUrl.TrimEnd('/') + "/aowlspt/basement" + path;

    public string? Get(string path)
    {
        Calls++;
        try
        {
            using var cts = new CancellationTokenSource(Cfg.TimeoutMs);
            using var r = _http.GetAsync(Route(path), cts.Token).GetAwaiter().GetResult();
            var body = r.Content.ReadAsStringAsync(cts.Token).GetAwaiter().GetResult();
            if (!r.IsSuccessStatusCode) return Fail("GET " + path + " -> HTTP " + (int)r.StatusCode + " " + Head(body));
            return body;
        }
        catch (Exception ex) { return Fail("GET " + path + " -> " + ex.GetType().Name + ": " + ex.Message); }
    }

    public string? Post(string path, object payload)
    {
        Calls++;
        try
        {
            using var cts = new CancellationTokenSource(Cfg.TimeoutMs);
            using var content = new StringContent(JsonSerializer.Serialize(payload, Json), Encoding.UTF8, "application/json");
            using var r = _http.PostAsync(Route(path), content, cts.Token).GetAwaiter().GetResult();
            var body = r.Content.ReadAsStringAsync(cts.Token).GetAwaiter().GetResult();
            if (!r.IsSuccessStatusCode) return Fail("POST " + path + " -> HTTP " + (int)r.StatusCode + " " + Head(body));
            return body;
        }
        catch (Exception ex) { return Fail("POST " + path + " -> " + ex.GetType().Name + ": " + ex.Message); }
    }

    public T? Parse<T>(string? body, string what) where T : class
    {
        if (body == null) return null;
        try { return JsonSerializer.Deserialize<T>(body, Json); }
        catch (Exception ex) { Fail(what + " answered non-JSON (" + ex.Message + "): " + Head(body)); return null; }
    }

    private string? Fail(string why)
    {
        Failures++; LastError = why;
        _log.Warning("[Basement.Server] sidecar " + why + " -- SPT's own output is used unchanged for this call.", null);
        return null;
    }
    private static string Head(string s) => s.Length > 160 ? s.Substring(0, 160) + "..." : s;
}
