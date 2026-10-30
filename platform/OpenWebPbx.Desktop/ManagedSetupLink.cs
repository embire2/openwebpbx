using System.Text.RegularExpressions;

namespace OpenWebPbx_Desktop;

internal static class ManagedSetupLink
{
    internal static string? VerifiedWizard(string? url, string? code) =>
        code is not null && Regex.IsMatch(code, @"\A[A-F0-9]{5}-[A-F0-9]{5}\z", RegexOptions.CultureInvariant)
        && url == "https://openwebpbx.com/wizard#code=" + code ? url : null;

    internal static bool IsCanonicalAddress(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == "https"
        && uri.Port == 443 && uri.UserInfo.Length == 0 && uri.AbsolutePath == "/"
        && uri.Query.Length == 0 && uri.Fragment.Length == 0
        && Regex.IsMatch(uri.IdnHost, @"\Anode-[a-f0-9]{32}\.openwebpbx\.com\z", RegexOptions.CultureInvariant);
}
