using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Aowl.Api;

if (args.Length == 0) { Console.WriteLine("usage: resample | stream <wav> [url] [chunkMs] [srcRate]"); return 2; }
// 48 kHz has an integer step (3) and never interpolates; 44.1 kHz (step 2.75625) exercises the fractional carry.
if (args[0] == "resample") return Math.Max(Resample(48000), Resample(44100));
if (args[0] == "stream") return await Stream(args);
return 2;

static int Resample(int src)
{
    // 2 s of a 440 Hz sine at `src` Hz, pushed in 250 ms pieces exactly as PumpMic does.
    const int dst = 16000, secs = 2;
    var rs = new Resampler(src, dst);
    var all = new List<byte>();
    int per = src / 4;
    var chunk = new float[per];
    for (int c = 0; c < secs * 4; c++)
    {
        for (int i = 0; i < per; i++) chunk[i] = (float)Math.Sin(2 * Math.PI * 440 * (c * per + i) / (double)src) * 0.5f;
        all.AddRange(rs.Push(chunk, per));
    }
    int outSamples = all.Count / 2;
    int expect = secs * dst;
    // Compare against the ideal 16 kHz sine (440 Hz is far below Nyquist; linear interpolation error is small).
    double maxErr = 0; var b = all.ToArray();
    for (int i = 0; i < outSamples; i++)
    {
        short s = (short)(b[i * 2] | (b[i * 2 + 1] << 8));
        double ideal = Math.Sin(2 * Math.PI * 440 * i / (double)dst) * 0.5;
        maxErr = Math.Max(maxErr, Math.Abs(s / 32767.0 - ideal));
    }
    // Negative control: a resampler without the cross-push carry is short by ~1 sample per push
    // (8 pushes -> delta -8) and restarts the phase at every boundary (error > 0.01).
    bool ok = Math.Abs(outSamples - expect) <= 1 && maxErr < 0.01;
    Console.WriteLine($"resample {src}->16000: in={rs.SamplesIn} out={outSamples} (expected {expect}, delta {outSamples - expect}), max abs error vs ideal sine = {maxErr:0.0000} -> {(ok ? "PASS" : "FAIL")}");
    return ok ? 0 : 1;
}

static async Task<int> Stream(string[] a)
{
    var wavPath = a[1];
    var url = a.Length > 2 ? a[2] : "http://127.0.0.1:6970";
    int chunkMs = a.Length > 3 ? int.Parse(a[3]) : 250;
    int srcRate = a.Length > 4 ? int.Parse(a[4]) : 16000;
    var wav = File.ReadAllBytes(wavPath);
    int fmt = Find(wav, "fmt "), data = Find(wav, "data");
    if (fmt < 0 || data < 0) { Console.WriteLine("not a wav"); return 1; }
    int channels = wav[fmt + 10] | (wav[fmt + 11] << 8);
    int rate = BitConverter.ToInt32(wav, fmt + 12);
    int bits = wav[fmt + 22] | (wav[fmt + 23] << 8);
    int size = BitConverter.ToInt32(wav, data + 4); int start = data + 8;
    if (start + size > wav.Length) size = wav.Length - start;
    if (rate != 16000 || channels != 1 || bits != 16) { Console.WriteLine($"want 16000/1/16, got {rate}/{channels}/{bits}"); return 1; }
    int n = size / 2;
    var f16 = new float[n];
    for (int i = 0; i < n; i++) f16[i] = (short)(wav[start + i * 2] | (wav[start + i * 2 + 1] << 8)) / 32768f;
    // Imitate the microphone: upsample (linear) to srcRate; the plugin's Resampler must bring it back to 16 kHz.
    float[] mic = f16;
    if (srcRate != 16000)
    {
        int m = (int)((long)n * srcRate / 16000);
        mic = new float[m];
        for (int i = 0; i < m; i++) { double p = i * 16000.0 / srcRate; int i0 = (int)p; int i1 = Math.Min(i0 + 1, n - 1); double fr = p - i0; mic[i] = (float)(f16[i0] + (f16[i1] - f16[i0]) * fr); }
    }
    var rs = new Resampler(srcRate, 16000);
    int perChunk = srcRate * chunkMs / 1000;
    var http = new HttpClient();
    http.DefaultRequestHeaders.TryAddWithoutValidation("Accept-Encoding", "identity");
    var session = "chunkcheck-" + Guid.NewGuid().ToString("N");
    var sw = Stopwatch.StartNew();
    int seq = 0; long sent = 0; int partials = 0; string lastPartial = ""; string finalText = ""; bool refused = false;
    long firstPartialAt = -1, finalAt = -1;
    Console.WriteLine($"stream {Path.GetFileName(wavPath)}: {n} samples = {n / 16.0:0} ms of speech, imitating a {srcRate} Hz mic, {chunkMs} ms chunks ({perChunk} src samples), session {session}");
    for (int off = 0; off < mic.Length || seq == 0; off += perChunk)
    {
        int cnt = Math.Min(perChunk, mic.Length - off);
        if (cnt < 0) cnt = 0;
        var piece = new float[cnt]; Array.Copy(mic, off, piece, 0, cnt);
        var pcm = rs.Push(piece, cnt);
        bool final = off + perChunk >= mic.Length;
        var body = new Dictionary<string, object> { ["session"] = session, ["seq"] = seq, ["final"] = final };
        if (pcm.Length > 0) body["wavBase64"] = Convert.ToBase64String(pcm);
        if (seq == 0) body["personId"] = "";
        // Real time: do not post a chunk before its audio would have been captured.
        long due = (long)off * 1000 / srcRate + chunkMs;
        long wait = due - sw.ElapsedMilliseconds; if (wait > 0) await Task.Delay((int)wait);
        var t0 = sw.ElapsedMilliseconds;
        var resp = await http.PostAsync(url + "/aowlspt/basement/speech/chunk", new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"));
        var text = await resp.Content.ReadAsStringAsync();
        var t1 = sw.ElapsedMilliseconds;
        sent += pcm.Length; seq++;
        try
        {
            using var doc = JsonDocument.Parse(text);
            var r = doc.RootElement;
            bool ok = r.TryGetProperty("ok", out var okp) && okp.GetBoolean();
            string partial = r.TryGetProperty("partial", out var pp) ? pp.GetString() ?? "" : "";
            string fin = r.TryGetProperty("final", out var fp) ? fp.GetString() ?? "" : "";
            string note = r.TryGetProperty("note", out var np) ? np.GetString() ?? "" : "";
            if (!ok) { refused = true; Console.WriteLine($"  t={t0,6} ms seq {seq - 1}: REFUSED HTTP {(int)resp.StatusCode} -- {note}  body={text[..Math.Min(200, text.Length)]}"); continue; }
            if (partial.Length > 0 && partial != lastPartial)
            {
                partials++; lastPartial = partial; if (firstPartialAt < 0) firstPartialAt = t1;
                Console.WriteLine($"  t={t1,6} ms seq {seq - 1}: PARTIAL \"{partial}\"  (request {t1 - t0} ms)");
            }
            else if (final) { finalAt = t1; Console.WriteLine($"  t={t1,6} ms seq {seq - 1}: FINAL \"{fin}\"  (request {t1 - t0} ms) -- {note}"); }
            else Console.WriteLine($"  t={t1,6} ms seq {seq - 1}: ok, {pcm.Length} B, request {t1 - t0} ms -- {Short(note)}");
            if (final) finalText = fin;
        }
        catch (Exception ex) { refused = true; Console.WriteLine($"  seq {seq - 1}: unparseable reply ({ex.Message}): {text[..Math.Min(200, text.Length)]}"); }
        if (final) break;
    }
    long speechMs = n / 16;
    Console.WriteLine($"done: {seq} chunks, {sent} PCM bytes ({sent / 32} ms of audio), {partials} distinct partial(s), first partial at {firstPartialAt} ms, final \"{finalText}\" at {finalAt} ms = {finalAt - speechMs} ms after the last sample; resampler in={rs.SamplesIn} out={rs.SamplesOut}");
    return refused || finalText.Length == 0 ? 1 : 0;
}

static string Short(string s) => s.Length > 90 ? s[..90] + "..." : s;
static int Find(byte[] w, string id) { for (int i = 12; i < w.Length - 8; i++) if (w[i] == id[0] && w[i + 1] == id[1] && w[i + 2] == id[2] && w[i + 3] == id[3]) return i; return -1; }
