using System.Reflection;
using System.Text.Json;
using SPTarkov.Server.Core.Helpers.Server;

namespace Basement.Server;

public sealed class Config
{
    public bool Enabled { get; set; } = true;
    public string SidecarUrl { get; set; } = "http://127.0.0.1:6970";
    public int TimeoutMs { get; set; } = 3000;
    public bool RewriteCounts { get; set; } = true;
    public bool RewriteNames { get; set; } = true;
    public bool RewriteLoadouts { get; set; } = true;
    public bool RewriteWaves { get; set; } = true;
    /// <summary>EXPERIMENT, default off: also write the plan's groupId into Info.GroupId. The client
    /// feeds Profile.Info.GroupId to BotsGroup.AddEnemyGroupIfAllowed, so this may change hostility.</summary>
    public bool WriteGroupId { get; set; } = false;

    public static Config Load(ModHelper modHelper, out string source)
    {
        var dir = modHelper.GetAbsolutePathToModFolder(Assembly.GetExecutingAssembly());
        var path = Path.Combine(dir, "config.json");
        source = path;
        if (!File.Exists(path)) { source = path + " (ABSENT, defaults)"; return new Config(); }
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
        return JsonSerializer.Deserialize<Config>(File.ReadAllText(path), opts) ?? new Config();
    }
}
