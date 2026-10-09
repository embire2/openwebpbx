using System.Net;
using System.Net.Http.Headers;

namespace OpenWebPbx.Updater;

public sealed class DownloadClient : IDisposable
{
    private readonly HttpClient client;
    public DownloadClient(HttpMessageHandler? handler = null)
    {
        client = new HttpClient(handler ?? new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(15), AutomaticDecompression = DecompressionMethods.None });
        client.Timeout = Timeout.InfiniteTimeSpan;
        client.DefaultRequestHeaders.UserAgent.ParseAdd("OpenWebPBX-Updater/1");
    }
    public static bool Allowed(Uri uri) => uri.Scheme == "https" && uri.Port == 443 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 && uri.AbsoluteUri.Length <= 16384 &&
        ((uri.Host == "github.com" && (uri.AbsolutePath.StartsWith("/embire2/openwebpbx/releases/download/", StringComparison.Ordinal) || uri.AbsolutePath == "/embire2/openwebpbx/releases/latest/download/update-manifest.json")) ||
        uri.Host is "release-assets.githubusercontent.com" or "objects.githubusercontent.com");
    private async Task<HttpResponseMessage> Get(string url, long offset, CancellationToken ct)
    {
        var uri = new Uri(url);
        for (var redirect = 0; redirect <= 5; redirect++)
        {
            if (!Allowed(uri)) throw new InvalidDataException("The update server redirected to an untrusted location.");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                var location = response.Headers.Location; response.Dispose();
                if (location is null) throw new InvalidDataException("The update redirect is incomplete.");
                uri = location.IsAbsoluteUri ? location : new Uri(uri, location); continue;
            }
            return response;
        }
        throw new InvalidDataException("The update server redirected too many times.");
    }
    public async Task<byte[]> Feed(CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(45));
        using var response = await Get(UpdaterPaths.FeedUrl, 0, timeout.Token); response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > 262144) throw new InvalidDataException("Release metadata exceeds its limit.");
        using var input = await response.Content.ReadAsStreamAsync(timeout.Token); using var output = new MemoryStream();
        var buffer = new byte[16384];
        while (true) { var count = await input.ReadAsync(buffer, timeout.Token); if (count == 0) break; if (output.Length + count > 262144) throw new InvalidDataException("Release metadata exceeds its limit."); await output.WriteAsync(buffer.AsMemory(0, count), timeout.Token); }
        return output.ToArray();
    }
    public async Task<string> Download(ReleaseAsset asset, string directory, Func<long, Task> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(directory);
        var complete = Path.Combine(directory, asset.Sha256 + ".archive");
        if (File.Exists(complete))
        {
            try { await ReleaseVerifier.VerifyArchive(complete, asset, ct); return complete; }
            catch (InvalidDataException) { File.Delete(complete); }
        }
        var partial = complete + ".partial";
        long offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (offset > asset.Bytes) { File.Delete(partial); offset = 0; }
        if (offset < asset.Bytes)
        {
            var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(directory))!);
            if (drive.AvailableFreeSpace < asset.Bytes - offset + 256L * 1024 * 1024) throw new IOException("There is not enough free space to download this update.");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromHours(2));
            using var response = await Get(asset.Url, offset, deadline.Token);
            response.EnsureSuccessStatusCode();
            if (response.StatusCode == HttpStatusCode.PartialContent)
            {
                var range = response.Content.Headers.ContentRange;
                if (range?.From != offset || range.To != asset.Bytes - 1 || range.Length != asset.Bytes) throw new InvalidDataException("The update server returned an invalid download range.");
            }
            else if (response.StatusCode == HttpStatusCode.OK) offset = 0;
            else throw new InvalidDataException("The update server returned an unexpected response.");
            if (response.Content.Headers.ContentLength is long length && length != asset.Bytes - offset) throw new InvalidDataException("The update server returned an unexpected download size.");
            using var output = new FileStream(partial, offset == 0 ? FileMode.Create : FileMode.Open, FileAccess.Write, FileShare.None, 131072, FileOptions.Asynchronous);
            output.Position = offset;
            using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
            var buffer = new byte[131072]; var lastReport = DateTimeOffset.MinValue;
            while (true)
            {
                using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token); readTimeout.CancelAfter(TimeSpan.FromSeconds(60));
                var count = await input.ReadAsync(buffer, readTimeout.Token); if (count == 0) break;
                if (output.Position + count > asset.Bytes) throw new InvalidDataException("The update download exceeds the signed size.");
                await output.WriteAsync(buffer.AsMemory(0, count), deadline.Token);
                if (DateTimeOffset.UtcNow - lastReport > TimeSpan.FromSeconds(1)) { await progress(output.Position); lastReport = DateTimeOffset.UtcNow; }
            }
            await output.FlushAsync(deadline.Token); output.Flush(flushToDisk: true);
        }
        try { await ReleaseVerifier.VerifyArchive(partial, asset, ct); }
        catch (InvalidDataException) { File.Delete(partial); throw; }
        File.Move(partial, complete, overwrite: true); await progress(asset.Bytes); return complete;
    }
    public void Dispose() => client.Dispose();
}
