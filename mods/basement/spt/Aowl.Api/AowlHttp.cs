using System;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace Aowl.Api
{
    /// <summary>
    /// The one HttpClient, and the three outcomes every call has: a transport
    /// error, an HTTP status, or a parsed JSON object. The synchronous
    /// variants exist for background threads only -- never call them from
    /// Update(). Public so a consumer can reach a backend route this API does
    /// not wrap; every route lives under <see cref="Route"/>.
    /// </summary>
    public static class AowlHttp
    {
        /// <summary>Base URL of the backend, e.g. <c>http://127.0.0.1:6970</c>. Set from <c>[Backend] Url</c> at load.</summary>
        public static string BaseUrl = "http://127.0.0.1:6970";

        private static readonly HttpClient Client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };

        /// <summary>One HTTP answer, in the three-outcome shape.</summary>
        public sealed class Reply
        {
            /// <summary>HTTP status; 0 when the transport failed.</summary>
            public int Status;
            /// <summary>The raw body ("" on transport failure).</summary>
            public string Body = "";
            /// <summary>Transport-level error; null when an HTTP answer arrived.</summary>
            public string Error;
            /// <summary>The parsed body; null when it is not a JSON object.</summary>
            public JObject Json;
            /// <summary>True only for HTTP 200 with a JSON object carrying <c>ok:true</c>.</summary>
            public bool Ok => Error == null && Status == 200 && Json != null && (Json.Value<bool?>("ok") ?? false);
            /// <summary>The best one-line reason when <see cref="Ok"/> is false: the backend's <c>err</c>, its <c>note</c>, the transport error, or the status.</summary>
            public string Err => Json?.Value<string>("err") ?? Json?.Value<string>("note") ?? Error ?? ("HTTP " + Status);
            /// <summary>The first <paramref name="n"/> characters of the body, for a log line.</summary>
            public string Head(int n = 200) => Body.Length > n ? Body.Substring(0, n) : Body;
        }

        /// <summary>The absolute URL of a backend route: <c>BaseUrl + "/aowlspt/basement" + path</c>.</summary>
        public static string Route(string path)
        {
            var b = BaseUrl ?? "";
            while (b.EndsWith("/")) b = b.Substring(0, b.Length - 1);
            return b + "/aowlspt/basement" + path;
        }

        /// <summary>Send one request. Never throws: a failure is <see cref="Reply.Error"/>.</summary>
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

        /// <summary>GET, any thread.</summary>
        public static Task<Reply> GetAsync(string url, int timeoutMs) => SendAsync(HttpMethod.Get, url, null, timeoutMs);
        /// <summary>POST a JSON body ("{}" when null), any thread.</summary>
        public static Task<Reply> PostAsync(string url, string body, int timeoutMs) => SendAsync(HttpMethod.Post, url, body ?? "{}", timeoutMs);

        /// <summary>Background threads only.</summary>
        public static Reply Get(string url, int timeoutMs) => GetAsync(url, timeoutMs).GetAwaiter().GetResult();
        /// <summary>Background threads only.</summary>
        public static Reply Post(string url, string body, int timeoutMs) => PostAsync(url, body, timeoutMs).GetAwaiter().GetResult();
    }
}
