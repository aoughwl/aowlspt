// The single SPT route that fans out to every native mod route.
//
// SPT builds its routers through DI, at startup, before any native mod has had
// a chance to run — so a mod that registers a route in `on_load` would have
// missed the registration window entirely. Rather than fight that, one dynamic
// router claims the `/aowlspt/` prefix and resolves the actual handler per
// request from the live route table.
//
// The cost is one dictionary lookup per request on a prefix nothing else uses.
// The benefit is that mods can add and remove routes at any time, including
// across a hot reload, with no involvement from SPT's container.

using System.Text.Json;
using System.Text.Json.Serialization;
using SPTarkov.DI.Annotations;
using SPTarkov.Server.Core.DI;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Utils;
using SPTarkov.Server.Core.Utils;

namespace Aowlspt.Host.Server;

/// <summary>
/// A request body of any shape.
///
/// SPT deserializes each request into the <c>bodyType</c> its RouteAction
/// declares, before the handler runs. Declaring <c>EmptyRequestData</c> means
/// any body with actual fields in it fails to deserialize and the request dies
/// with "'p' is an invalid start of a property name" — which reads like a
/// malformed request rather than what it is, a route that refuses input.
///
/// <see cref="JsonExtensionData"/> soaks up every property instead, so a mod
/// receives whatever the caller sent.
/// </summary>
public sealed class AowlsptRawRequest : IRequestData
{
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Fields { get; set; }

    public string ToJson() =>
        Fields is null or { Count: 0 } ? "{}" : JsonSerializer.Serialize(Fields);
}

[Injectable(InjectionType.Singleton)]
public sealed class AowlsptRouter : DynamicRouter
{
    /// <summary>The URL prefix every native mod route lives under.</summary>
    public const string Prefix = "/aowlspt/";

    public AowlsptRouter(JsonUtil jsonUtil)
        : base(jsonUtil, new List<RouteAction>
        {
            new(Prefix, HandleAsync, typeof(AowlsptRawRequest)),
        })
    {
    }

    private static ValueTask<object> HandleAsync(
        string url,
        IRequestData? request,
        MongoId sessionId,
        string output,
        CancellationToken cancellationToken)
    {
        var services = ModEntry.Live;
        if (services is null)
            return new ValueTask<object>(Error("aowlspt host is not running"));

        // Prefer the parsed body; fall back to whatever SPT put in `output`.
        var body = request is AowlsptRawRequest raw ? raw.ToJson() : (output ?? "{}");

        if (!services.TryDispatch(url, body, sessionId.ToString(), out var response))
            return new ValueTask<object>(Error($"no native mod serves '{url}'"));

        // A handler that returns nothing still owes the client a valid body.
        return new ValueTask<object>(string.IsNullOrEmpty(response) ? "{}" : response);
    }

    private static string Error(string message) =>
        JsonSerializer.Serialize(new { err = 1, errmsg = message });
}
