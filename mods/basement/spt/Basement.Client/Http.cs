using System;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace Basement.Client
{
    /// <summary>
    /// The one HttpClient, and the three outcomes every call has: a transport
    /// error, an HTTP status, or a parsed JSON object. The synchronous
    /// variants exist for background threads only -- never call them from
    /// Update().
    /// </summary>
    internal static class Http
    {
        public static string BaseUrl = "http://127.0.0.1:6970";

        private static readonly HttpClient Client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };

        public sealed class Reply
        {
            public int Status;
            public string Body = "";
            public string Error;        // transport-level; null when an HTTP answer arrived
            public JObject Json;        // null when the body is not a JSON object
            public bool Ok => Error == null && Status == 200 && Json != null && (Json.Value<bool?>("ok") ?? false);
            public string Err => Json?.Value<string>("err") ?? Json?.Value<string>("note") ?? Error ?? ("HTTP " + Status);
            public string Head(int n = 200) => Body.Length > n ? Body.Substring(0, n) : Body;
        }

        public static string Route(string path)
        {
            var b = BaseUrl ?? "";
            while (b.EndsWith("/")) b = b.Substring(0, b.Length - 1);
            return b + "/aowlspt/basement" + path;
        }

        public static async Task<Reply> SendAsync(HttpMethod method, string url, string body, int timeoutMs)
        {
            var r = new Reply();
            try
            {
                using (var req = new HttpRequestMessage(method, url))
                using (var cts = new CancellationTokenSource(timeoutMs))
                {
                    // The backend can deflate; asking for identity keeps the body readable.
                    req.Headers.TryAddWithoutValidation("Accept-Encoding", "identity");
                    if (body != null)
                        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
                    using (var resp = await Client.SendAsync(req, cts.Token).ConfigureAwait(false))
                    {
                        r.Status = (int)resp.StatusCode;
                        r.Body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    }
                }
                try { r.Json = JObject.Parse(r.Body); } catch { r.Json = null; }
            }
            catch (Exception ex)
            {
                r.Error = ex.GetType().Name + ": " + ex.Message;
            }
            return r;
        }

        public static Task<Reply> GetAsync(string url, int timeoutMs) => SendAsync(HttpMethod.Get, url, null, timeoutMs);
        public static Task<Reply> PostAsync(string url, string body, int timeoutMs) => SendAsync(HttpMethod.Post, url, body ?? "{}", timeoutMs);

        /// <summary>Background threads only.</summary>
        public static Reply Get(string url, int timeoutMs) => GetAsync(url, timeoutMs).GetAwaiter().GetResult();
        public static Reply Post(string url, string body, int timeoutMs) => PostAsync(url, body, timeoutMs).GetAwaiter().GetResult();
    }
}
