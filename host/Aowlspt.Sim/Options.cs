using Aowlspt.Abi;

namespace Aowlspt.Sim;

internal sealed class Options
{
    public string Target = "";
    public int Ticks = 3;
    public int TickMs = 16;
    public string? DbFile;
    public string? StubFile;
    public AowlSide Side = AowlSide.Sim;
    public string SptVersion = "";
    public bool Watch;
    public bool Quiet;

    public readonly List<(string Url, string Body)> Routes = new();
    public readonly List<(string Name, string Payload)> Emits = new();

    public static Options Parse(string[] args)
    {
        var o = new Options { Target = args[0] };

        for (var i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--ticks": o.Ticks = NextInt(args, ref i); break;
                case "--tick-ms": o.TickMs = NextInt(args, ref i); break;
                case "--db": o.DbFile = Next(args, ref i); break;
                case "--stubs": o.StubFile = Next(args, ref i); break;
                case "--spt-version": o.SptVersion = Next(args, ref i); break;
                case "--watch": o.Watch = true; break;
                case "--quiet": o.Quiet = true; break;

                case "--side":
                    o.Side = Next(args, ref i).ToLowerInvariant() switch
                    {
                        "server" => AowlSide.Server,
                        "client" => AowlSide.Client,
                        "sim" => AowlSide.Sim,
                        var other => throw new ArgumentException($"unknown side '{other}'"),
                    };
                    break;

                // `--route /url,{"body":1}` — the first comma separates URL from
                // body, so a JSON body containing commas survives intact.
                case "--route":
                    o.Routes.Add(SplitOnce(Next(args, ref i)));
                    break;

                case "--emit":
                    o.Emits.Add(SplitOnce(Next(args, ref i)));
                    break;

                default:
                    throw new ArgumentException($"unknown option '{args[i]}'");
            }
        }

        if (o.Ticks < 0) throw new ArgumentException("--ticks cannot be negative");
        if (o.TickMs < 0) throw new ArgumentException("--tick-ms cannot be negative");
        return o;
    }

    private static string Next(string[] args, ref int i)
    {
        if (i + 1 >= args.Length) throw new ArgumentException($"{args[i]} needs a value");
        return args[++i];
    }

    private static int NextInt(string[] args, ref int i)
    {
        var name = args[i];
        var text = Next(args, ref i);
        if (!int.TryParse(text, out var v)) throw new ArgumentException($"{name} needs a number, got '{text}'");
        return v;
    }

    private static (string, string) SplitOnce(string value)
    {
        var comma = value.IndexOf(',');
        return comma < 0 ? (value, "") : (value[..comma], value[(comma + 1)..]);
    }
}
