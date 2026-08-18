using SPTarkov.Server.Core.Models.Spt.Mod;

namespace Aowlspt.Host.Server;

/// <summary>
/// What SPT's mod loader reads before it loads anything. This assembly is a
/// single ordinary SPT server mod; everything native it hosts is invisible to
/// SPT, which is the point — the loader stays a supported extension point and
/// the native side never has to track SPT's internals.
/// </summary>
public sealed record ModMetadata : IModMetadata
{
    public string ModGuid { get; init; } = "aowl.aowlspt.host";
    public string Name { get; init; } = "aowlspt host";
    public string Author { get; init; } = "aowlspt";
    public List<string>? Contributors { get; init; }
    public SemanticVersioning.Version Version { get; init; } = new("1.0.0", false);

    // Widen this only after checking the reflection surface still matches —
    // regenerate reference/spt-4.1-surface.json with tools/SptReflect first.
    public SemanticVersioning.Range SptVersion { get; init; } = new("~4.1.0", false);

    public List<string>? Incompatibilities { get; init; }
    public Dictionary<string, SemanticVersioning.Range>? ModDependencies { get; init; }
    public string? Url { get; init; } = "https://github.com/aoughwl/aowlspt";
    public bool? IsBundleMod { get; init; } = false;
    public string License { get; init; } = "MIT";
    public bool HasPrepatcher { get; init; } = false;
}
