// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Security.Cryptography;
namespace OpenWebPbx.Phone.Core;
/// <summary>Public release downloads never receive tenant bearer credentials or cookies.</summary>
public sealed class ReleaseDownload : IDisposable
{
    public static readonly Uri Catalogue = new("https://github.com/embire2/openwebpbx/releases/download/windows-phone-stable/windows-phone-update-manifest.json");
    private readonly HttpClient client;
    public ReleaseDownload(HttpMessageHandler? handler = null) => client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }, true) { Timeout = TimeSpan.FromSeconds(20) };
    private static void Approved(Uri target)
    {
        if (target.Scheme != "https" || target.Port != 443 || target.UserInfo != "" || target.Fragment != "" || target.Host is not ("github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com")) throw Invalid();
    }
    private async Task<HttpResponseMessage> Open(Uri target, CancellationToken cancellation)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            Approved(target); using var request = new HttpRequestMessage(HttpMethod.Get, target); request.Headers.UserAgent.ParseAdd("OpenWebPBX-WindowsPhone/1.0.0");
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
            {
                var next = response.Headers.Location; response.Dispose(); if (next is null) throw Invalid(); target = next.IsAbsoluteUri ? next : new Uri(target, next); continue;
            }
            if (response.StatusCode != HttpStatusCode.OK) { response.Dispose(); throw Invalid(); }
            return response;
        }
        throw Invalid();
    }
    public async Task<byte[]> CatalogueBytes(CancellationToken cancellation = default)
    {
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation); bounded.CancelAfter(TimeSpan.FromSeconds(20));
        using var response = await Open(Catalogue, bounded.Token); if (response.Content.Headers.ContentLength > 262144) throw Invalid();
        await using var input = await response.Content.ReadAsStreamAsync(bounded.Token); var buffer = new byte[262145]; var total = 0;
        while (total < buffer.Length) { var count = await input.ReadAsync(buffer.AsMemory(total), bounded.Token); if (count == 0) break; total += count; }
        if (total is 0 or > 262144) throw Invalid(); return buffer[..total];
    }
    public async Task<string> Package(ClientRelease release, string privateDirectory, IProgress<(long Received, long Total)>? progress = null, CancellationToken cancellation = default)
    {
        var expected = $"https://github.com/embire2/openwebpbx/releases/download/windows-phone-v{release.ReleaseVersion}/OpenWebPBX-Free-Phone-{release.ReleaseVersion}-win-x64.msixbundle";
        _ = ClientRelease.Version(release.ReleaseVersion); if (release.Package.AbsoluteUri != expected || release.Bytes is < 1000 or > 1073741824 || release.Sha256.Length != 64 || release.Sha256.Any(c => !char.IsAsciiHexDigit(c))) throw Invalid();
        var root = Path.GetFullPath(privateDirectory); if (!Directory.Exists(root) || (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw Invalid();
        var temporary = Path.Combine(root, Guid.NewGuid().ToString("N") + ".partial");
        var final = Path.Combine(root, "WindowsPhone-" + release.ReleaseVersion + "-" + release.Sha256.ToLowerInvariant() + ".msixbundle");
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation); bounded.CancelAfter(TimeSpan.FromMinutes(15));
        try
        {
            using var response = await Open(release.Package, bounded.Token);
            if (response.Content.Headers.ContentLength is long length && length != release.Bytes) throw Invalid();
            await using var input = await response.Content.ReadAsStreamAsync(bounded.Token); using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256); long total = 0; var buffer = new byte[65536];
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
            {
                while (true)
                {
                    using var read = CancellationTokenSource.CreateLinkedTokenSource(bounded.Token); read.CancelAfter(TimeSpan.FromSeconds(30));
                    var count = await input.ReadAsync(buffer, read.Token); if (count == 0) break; total += count; if (total > release.Bytes) throw Invalid();
                    sha.AppendData(buffer, 0, count); await output.WriteAsync(buffer.AsMemory(0, count), bounded.Token); progress?.Report((total, release.Bytes));
                }
                output.Flush(true);
            }
            if (total != release.Bytes || !Convert.ToHexString(sha.GetHashAndReset()).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase)) throw Invalid();
            // A completed download is promoted only after exact length and hash; the prior app is untouched.
            File.Move(temporary, final, true); return final;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static PhoneInputException Invalid() => new("The verified Windows phone update could not be downloaded. The current app has been kept.");
    public void Dispose() => client.Dispose();
}
