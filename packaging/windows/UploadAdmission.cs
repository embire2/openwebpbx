// SPDX-License-Identifier: AGPL-3.0-or-later
// IIS integrated-pipeline admission runs before PHP or any request-body read.
using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web;

namespace OpenWebPbx.Windows {
    public sealed class UploadAdmission : IHttpModule {
        private static readonly Regex Upload = new Regex(@"^/(?:app/pbx_protection/upload\.php(?:\?tenant=[a-f0-9-]*)?|api/v2/(?:instance/backups/import|tenants/[a-f0-9-]+/backups/import))$", RegexOptions.CultureInvariant);
        private static readonly Regex BackupRoute = new Regex(@"\A/(?:instance/backups/import|tenants/[a-f0-9-]+/backups/import)\z", RegexOptions.CultureInvariant);
        private static bool IsBackupImportAlias(HttpRequest request) {
            string path = request.Path;
            if (!path.Equals("/api/v2", StringComparison.OrdinalIgnoreCase) &&
                !path.Equals("/api/v2/", StringComparison.OrdinalIgnoreCase) &&
                !path.Equals("/api/v2/index.php", StringComparison.OrdinalIgnoreCase)) return false;
            // Query parsing never touches Form, Params or the upload body.
            // GetValues retains duplicate values; PHP must not receive a
            // backup-import alias under the ordinary multipart parser.
            string[] routes = HttpUtility.ParseQueryString(request.Url.Query).GetValues("route");
            if (routes == null) return false;
            foreach (string route in routes) if (route != null && BackupRoute.IsMatch(route)) return true;
            return false;
        }
        public void Init(HttpApplication app) { app.BeginRequest += Admit; }
        public void Dispose() { }
        private static void Refuse(HttpContext context, int status) {
            context.Response.StatusCode = status;
            context.Response.TrySkipIisCustomErrors = true;
            context.Response.ContentType = "application/json";
            context.Response.Cache.SetCacheability(HttpCacheability.NoCache);
            context.Response.Write("{\"error\":{\"code\":\"upload_refused\",\"message\":\"Upload refused. Check sign-in, access, backup password, size and storage.\"}}");
            context.ApplicationInstance.CompleteRequest();
        }
        private static void Admit(object sender, EventArgs args) {
            HttpContext context = ((HttpApplication)sender).Context;
            string uri = context.Request.RawUrl;
            context.Request.Headers.Remove("X-OpenWeb-Admission");
            context.Request.Headers.Remove("X-OpenWeb-Admission-Uri");
            // The internal rewrite target cannot be used to bypass admission.
            if (uri.StartsWith("/api/v2/upload.php", StringComparison.OrdinalIgnoreCase) || uri.StartsWith("/app/pbx_protection/upload_gate.php", StringComparison.OrdinalIgnoreCase)) { Refuse(context, 404); return; }
            if (!Upload.IsMatch(uri)) {
                if (IsBackupImportAlias(context.Request) || context.Request.Path.Equals("/app/pbx_protection/upload.php", StringComparison.OrdinalIgnoreCase) || (context.Request.Path.StartsWith("/api/v2/", StringComparison.OrdinalIgnoreCase) && context.Request.ContentType == "application/octet-stream")) Refuse(context, 403);
                return;
            }
            if (uri.Length > 512 || !context.Request.IsSecureConnection || context.Request.HttpMethod != "POST") { Refuse(context, 403); return; }
            try {
                string keyPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"OpenWebPBX\upload-admission\gate.key");
                FileInfo keyFile = new FileInfo(keyPath);
                if (!keyFile.Exists || keyFile.Length != 64 || (keyFile.Attributes & FileAttributes.ReparsePoint) != 0) { Refuse(context, 503); return; }
                string secret = File.ReadAllText(keyPath);
                if (!Regex.IsMatch(secret, "\\A[a-f0-9]{64}\\z")) { Refuse(context, 503); return; }
                HttpWebRequest gate = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:9089/index.php");
                gate.Proxy = null; gate.Method = "POST"; gate.ContentLength = 0;
                gate.AllowAutoRedirect = false; gate.Timeout = 15000; gate.ReadWriteTimeout = 15000;
                gate.Headers["X-OpenWeb-Gate-Secret"] = secret;
                gate.Headers["X-OpenWeb-Upload-Method"] = context.Request.HttpMethod;
                gate.Headers["X-OpenWeb-Upload-Length"] = context.Request.Headers["Content-Length"] ?? "";
                gate.Headers["X-OpenWeb-Upload-Type"] = context.Request.ContentType ?? "";
                gate.Headers["X-OpenWeb-Upload-Uri"] = uri;
                gate.Headers["X-OpenWeb-Upload-Host"] = context.Request.Headers["Host"] ?? "";
                gate.Headers["X-OpenWeb-Upload-Address"] = context.Request.UserHostAddress;
                foreach (string name in new [] { "Authorization", "Cookie", "Origin", "X-OpenWeb-Token-Name", "X-OpenWeb-Token", "X-Backup-Password" }) {
                    string value = context.Request.Headers[name];
                    if (value != null) gate.Headers["X-OpenWeb-Original-" + name] = value;
                }
                using (HttpWebResponse response = (HttpWebResponse)gate.GetResponse()) {
                    if (response.StatusCode != HttpStatusCode.NoContent) { Refuse(context, 403); return; }
                }
                // A header supplied by a client never substitutes for the gate.
                // Bind the internal handoff to this raw route, length and time.
                string issued = ((long)(DateTime.UtcNow - new DateTime(1970,1,1)).TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
                string data = issued + "\n" + uri + "\n" + (context.Request.Headers["Content-Length"] ?? "");
                using (HMACSHA256 hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret))) {
                    string proof = BitConverter.ToString(hmac.ComputeHash(Encoding.UTF8.GetBytes(data))).Replace("-", "").ToLowerInvariant();
                    context.Request.Headers.Set("X-OpenWeb-Admission", issued + "." + proof);
                    context.Request.Headers.Set("X-OpenWeb-Admission-Uri", uri);
                }
            } catch (WebException error) {
                using (HttpWebResponse response = error.Response as HttpWebResponse) {
                    Refuse(context, response != null && response.StatusCode == HttpStatusCode.Unauthorized ? 401 : 403);
                }
            } catch { Refuse(context, 503); }
        }
    }
}
