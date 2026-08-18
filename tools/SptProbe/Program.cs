// sptprobe — call an SPT server route the way the EFT client does.
//
// You cannot test an SPT route with curl, and that is not obvious until you have
// lost an hour to it. SPT's SptHttpListener reads every request body through a
// zlib stream and writes every response back the same way, because the real
// client always speaks compressed. A plain JSON body fails to inflate and the
// request dies before any router is consulted — the server answers 200 with an
// empty body and logs "unsupported compression method", which looks like a
// broken mod rather than a malformed request.
//
// So: zlib in, zlib out, and the response printed as text.
//
//   sptprobe <url> [--body JSON] [--session ID] [--get] [--raw]
//
// Certificate validation is disabled: SPT generates a self-signed certificate
// for localhost, and this only ever talks to a local server.

using System.IO.Compression;
using System.Net.Security;
using System.Text;

namespace Aowlspt.Tools.SptProbe;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help")
        {
            Console.Error.WriteLine("""
                sptprobe — call an SPT route with the compression the server expects

                  sptprobe <url> [options]

                    --body JSON     request body (default "{}")
                    --body-file F   read the request body from a file
                    --session ID    24-char hex session id (SPT parses it as a MongoId)
                    --get           issue GET instead of POST
                    --quiet         suppress the status line on stderr
                    --raw           print the raw bytes rather than inflating

                  sptprobe https://127.0.0.1:6969/aowlspt/hello
                """);
            return args.Length == 0 ? 2 : 0;
        }

        var url = args[0];
        var body = "{}";
        string? session = null;
        var get = false;
        var raw = false;
        var quiet = false;

        for (var i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--body" when i + 1 < args.Length: body = args[++i]; break;

                // Windows PowerShell strips double quotes when passing arguments
                // to a native executable, so `--body '{"a":1}'` arrives as
                // `{a:1}` and SPT rejects it as malformed JSON. Reading from a
                // file sidesteps shell quoting entirely.
                case "--body-file" when i + 1 < args.Length:
                    var path = args[++i];
                    if (!File.Exists(path))
                    {
                        Console.Error.WriteLine($"sptprobe: no such body file: {path}");
                        return 2;
                    }
                    body = File.ReadAllText(path);
                    break;
                case "--session" when i + 1 < args.Length: session = args[++i]; break;
                case "--get": get = true; break;
                case "--quiet": quiet = true; break;
                case "--raw": raw = true; break;
                default:
                    Console.Error.WriteLine($"sptprobe: unknown option '{args[i]}'");
                    return 2;
            }
        }

        var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback =
                (_, _, _, _) => true,
            AutomaticDecompression = System.Net.DecompressionMethods.None,
        };

        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(30) };

        HttpRequestMessage request;
        if (get)
        {
            request = new HttpRequestMessage(HttpMethod.Get, url);
        }
        else
        {
            request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new ByteArrayContent(ZlibCompress(body)),
            };
            request.Content.Headers.TryAddWithoutValidation("Content-Type", "application/json");
        }

        if (session is not null)
        {
            request.Headers.TryAddWithoutValidation("Cookie", $"PHPSESSID={session}");
            request.Headers.TryAddWithoutValidation("SessionId", session);
        }

        try
        {
            using var response = await client.SendAsync(request);
            var bytes = await response.Content.ReadAsByteArrayAsync();

            // Windows PowerShell turns a native command's stderr into a
            // terminating error under $ErrorActionPreference = 'Stop', so a
            // script driving this tool wants the status line gone entirely.
            if (!quiet)
                Console.Error.WriteLine($"[{(int)response.StatusCode} {response.StatusCode}] {bytes.Length} byte(s)");

            if (raw)
            {
                Console.WriteLine(Convert.ToHexString(bytes));
                return response.IsSuccessStatusCode ? 0 : 1;
            }

            Console.WriteLine(TryInflate(bytes));
            return response.IsSuccessStatusCode ? 0 : 1;
        }
        catch (HttpRequestException ex)
        {
            Console.Error.WriteLine($"sptprobe: {ex.Message}");
            return 1;
        }
        catch (TaskCanceledException)
        {
            Console.Error.WriteLine("sptprobe: timed out");
            return 1;
        }
    }

    private static byte[] ZlibCompress(string text)
    {
        var raw = Encoding.UTF8.GetBytes(text);
        using var output = new MemoryStream();
        using (var zlib = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true))
            zlib.Write(raw, 0, raw.Length);
        return output.ToArray();
    }

    /// <summary>
    /// SPT answers with zlib, but not always — an error produced before the
    /// compressing writer is reached comes back as plain bytes. Try both rather
    /// than reporting the interesting case as a decode failure.
    /// </summary>
    private static string TryInflate(byte[] bytes)
    {
        if (bytes.Length == 0) return "(empty body)";

        foreach (var attempt in new Func<byte[], string>[] { Zlib, Deflate })
        {
            try
            {
                var text = attempt(bytes);
                if (text.Length > 0) return text;
            }
            catch (InvalidDataException) { }
            catch (NotSupportedException) { }
        }
        return Encoding.UTF8.GetString(bytes);

        static string Zlib(byte[] b)
        {
            using var input = new MemoryStream(b);
            using var z = new ZLibStream(input, CompressionMode.Decompress);
            using var reader = new StreamReader(z, Encoding.UTF8);
            return reader.ReadToEnd();
        }

        static string Deflate(byte[] b)
        {
            using var input = new MemoryStream(b);
            using var d = new DeflateStream(input, CompressionMode.Decompress);
            using var reader = new StreamReader(d, Encoding.UTF8);
            return reader.ReadToEnd();
        }
    }
}
