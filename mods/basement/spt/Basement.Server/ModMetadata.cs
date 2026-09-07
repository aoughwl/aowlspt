using SPTarkov.Server.Core.Models.Spt.Mod;

namespace Basement.Server;

// IModMetadata members measured on SPTarkov.Server.Core 4.1.5.0: ModGuid, Name, Author,
// Contributors, Version, SptVersion, HasPrepatcher, Incompatibilities, ModDependencies,
// Url, License. (The EFMB scaffold's IsBundleMod is NOT on the 4.1.5 interface.)
public sealed record ModMetadata : IModMetadata
{
    public string ModGuid { get; init; } = "aowl.basement.server";
    public string Name { get; init; } = "Basement.Server";
    public string Author { get; init; } = "aowl";
    public List<string>? Contributors { get; init; }
    public SemanticVersioning.Version Version { get; init; } = new("0.1.0", false);
    public SemanticVersioning.Range SptVersion { get; init; } = new("~4.1.5", false);
    public List<string>? Incompatibilities { get; init; }
    public Dictionary<string, SemanticVersioning.Range>? ModDependencies { get; init; }
    public string? Url { get; init; }
    public string License { get; init; } = "Private";
    public bool HasPrepatcher { get; init; } = false;
}
