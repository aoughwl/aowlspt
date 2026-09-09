using Basement.Server.Patches;
using SPTarkov.DI.Annotations;
using SPTarkov.Server.Core.DI;
using SPTarkov.Server.Core.Models.Common;
using SPTarkov.Server.Core.Models.Eft.Common;
using SPTarkov.Server.Core.Utils;

namespace Basement.Server;

/// <summary>GET/POST http://127.0.0.1:6969/aowlspt/basement/spt/status on the SPT server itself:
/// the finished-state readback a verification can assert on (how many bots were planned,
/// named, re-kitted; how many waves written or dropped; the sidecar's last error).
/// StaticRouter(JsonUtil, IEnumerable&lt;RouteAction&gt;) and RouteAction&lt;T&gt;(url, Func&lt;string, T,
/// MongoId, string, CancellationToken, ValueTask&lt;string&gt;&gt;) measured on 4.1.5.</summary>
[Injectable]
public sealed class StatusRouter : StaticRouter
{
    public StatusRouter(JsonUtil jsonUtil, HttpResponseUtil http, Sidecar sidecar) : base(jsonUtil, new List<RouteAction>
    {
        new RouteAction<EmptyRequestData>("/aowlspt/basement/spt/status", (url, _, sessionId, output, ct) =>
        {
            var body = http.NoBody(new
            {
                mod = "Basement.Server",
                enabled = sidecar.Cfg.Enabled,
                sidecarUrl = sidecar.Cfg.SidecarUrl,
                sidecarCalls = sidecar.Calls,
                sidecarFailures = sidecar.Failures,
                sidecarLastError = sidecar.LastError,
                plan = PlanStore.Snapshot(),
                wavesWritten = LocationWavesPatch.WavesWritten,
                bossWavesWritten = LocationWavesPatch.BossWavesWritten,
                wavesDropped = LocationWavesPatch.WavesDropped,
            });
            return new ValueTask<string>(body);
        }),
    }) { }
}
