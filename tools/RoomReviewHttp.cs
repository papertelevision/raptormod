// RoomReviewHttp.cs -- the Room Review server's fallback transport (2026-10-08). Start-RoomReview.ps1 serves with
// System.Net.HttpListener; on a Windows where binding http://localhost:<port>/ needs elevation it uses this instead:
// a TcpListener on the LOOPBACK address only, one request per connection (Connection: close), Content-Length bodies,
// size caps, and any Host other than localhost / 127.0.0.1 refused (DNS rebinding).
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace AztTool
{
    public class MiniRequest
    {
        public string Method, RawUrl, Path, Query;
        public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public byte[] Body = new byte[0];
        internal TcpClient Client;
        /// <summary>Send the response and close the connection.</summary>
        public void Respond(int status, string contentType, byte[] body, Dictionary<string, string> headers)
        {
            try
            {
                var s = Client.GetStream(); body = body ?? new byte[0];
                var sb = new StringBuilder();
                sb.Append("HTTP/1.1 ").Append(status).Append(' ').Append(Reason(status)).Append("\r\n");
                if (!string.IsNullOrEmpty(contentType)) sb.Append("Content-Type: ").Append(contentType).Append("\r\n");
                sb.Append("Content-Length: ").Append(body.Length).Append("\r\n");
                if (headers != null) foreach (var kv in headers) sb.Append(kv.Key).Append(": ").Append(kv.Value).Append("\r\n");
                sb.Append("Connection: close\r\n\r\n");
                var h = Encoding.ASCII.GetBytes(sb.ToString());
                s.Write(h, 0, h.Length); if (Method != "HEAD") s.Write(body, 0, body.Length); s.Flush();
            }
            catch { }
            finally { try { Client.Close(); } catch { } }
        }
        static string Reason(int s)
        {
            switch (s) { case 200: return "OK"; case 204: return "No Content"; case 400: return "Bad Request"; case 403: return "Forbidden"; case 404: return "Not Found";
                case 405: return "Method Not Allowed"; case 413: return "Payload Too Large"; case 500: return "Internal Server Error"; default: return "Status"; }
        }
    }

    public class MiniHttp
    {
        TcpListener _l, _l6; public int Port;      // (both loopbacks: "localhost" resolves to ::1 first, and a client waits on it)
        public const int MaxHeader = 32 * 1024, MaxBody = 10 * 1024 * 1024;
        public void Start(int port)
        {
            _l = new TcpListener(IPAddress.Loopback, port); _l.Start(); Port = port;
            try { _l6 = new TcpListener(IPAddress.IPv6Loopback, port); _l6.Start(); } catch { _l6 = null; }      // (no IPv6 on this machine: IPv4 alone)
        }
        public void Stop() { try { _l.Stop(); } catch { } try { if (_l6 != null) _l6.Stop(); } catch { } }
        TcpListener Ready() { if (_l.Pending()) return _l; if (_l6 != null && _l6.Pending()) return _l6; return null; }
        /// <summary>The next request, or null if none came within timeoutMs (so the caller can notice Ctrl+C). A malformed
        /// or refused request is answered here and null returned.</summary>
        public MiniRequest Accept(int timeoutMs)
        {
            var ls = Ready();
            if (ls == null) { System.Threading.Thread.Sleep(Math.Min(timeoutMs, 50)); ls = Ready(); if (ls == null) return null; }
            var c = ls.AcceptTcpClient(); c.ReceiveTimeout = 5000; c.SendTimeout = 15000;
            var r = new MiniRequest { Client = c };
            try
            {
                var s = c.GetStream(); var head = new MemoryStream(); uint last4 = 0;
                // the header, byte by byte up to the blank line (\r\n\r\n)
                while (true)
                {
                    int b = s.ReadByte(); if (b < 0) { c.Close(); return null; }
                    head.WriteByte((byte)b);
                    last4 = (last4 << 8) | (uint)b;
                    if (last4 == 0x0D0A0D0Au) break;
                    if (head.Length > MaxHeader) { r.Respond(413, "text/plain", Encoding.ASCII.GetBytes("header too large"), null); return null; }
                }
                var lines = Encoding.ASCII.GetString(head.ToArray()).Split(new[] { "\r\n" }, StringSplitOptions.None);
                var first = lines[0].Split(' '); if (first.Length < 2) { r.Respond(400, "text/plain", null, null); return null; }
                r.Method = first[0].ToUpperInvariant(); r.RawUrl = first[1];
                for (int i = 1; i < lines.Length; i++) { int k = lines[i].IndexOf(':'); if (k > 0) r.Headers[lines[i].Substring(0, k).Trim()] = lines[i].Substring(k + 1).Trim(); }
                // only this machine's own names (a page elsewhere resolving its name to 127.0.0.1 is refused)
                string host; r.Headers.TryGetValue("Host", out host); host = (host ?? "").ToLowerInvariant();
                if (host != "localhost:" + Port && host != "127.0.0.1:" + Port && host != "[::1]:" + Port) { r.Respond(403, "text/plain", Encoding.ASCII.GetBytes("host refused"), null); return null; }
                string cl; long len = 0;
                if (r.Headers.TryGetValue("Content-Length", out cl) && !long.TryParse(cl, out len)) { r.Respond(400, "text/plain", null, null); return null; }
                if (len > MaxBody) { r.Respond(413, "text/plain", Encoding.ASCII.GetBytes("body too large"), null); return null; }
                if (len > 0)
                {
                    r.Body = new byte[len]; int got = 0;
                    while (got < len) { int n = s.Read(r.Body, got, (int)(len - got)); if (n <= 0) { c.Close(); return null; } got += n; }
                }
                int q = r.RawUrl.IndexOf('?');
                r.Path = q >= 0 ? r.RawUrl.Substring(0, q) : r.RawUrl; r.Query = q >= 0 ? r.RawUrl.Substring(q + 1) : "";
                return r;
            }
            catch { try { c.Close(); } catch { } return null; }
        }
    }
}
