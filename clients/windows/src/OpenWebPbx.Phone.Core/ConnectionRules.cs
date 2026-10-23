// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Phone.Core;

public static partial class ConnectionRules
{
    public const int MaximumProfiles = 10;
    public const int MaximumSetupBytes = 16_384;
    [GeneratedRegex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", RegexOptions.CultureInvariant)]
    private static partial Regex Label();
    [GeneratedRegex("^[A-Za-z0-9_-]{16,256}$", RegexOptions.CultureInvariant)]
    private static partial Regex SetupCode();
    [GeneratedRegex("^[0-9]{1,16}$", RegexOptions.CultureInvariant)]
    private static partial Regex ExtensionNumber();
    [GeneratedRegex("^[+*#0-9]{1,32}$", RegexOptions.CultureInvariant)]
    private static partial Regex DialString();

    public static Uri Tenant(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new PhoneInputException("Enter your tenant address.");
        var raw = value.Trim();
        if (Label().IsMatch(raw.ToLowerInvariant())) raw += ".openwebpbx.com";
        if (!raw.Contains("://", StringComparison.Ordinal)) raw = "https://" + raw;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps ||
            uri.Port != 443 || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 ||
            uri.AbsolutePath != "/" || !uri.Host.EndsWith(".openwebpbx.com", StringComparison.OrdinalIgnoreCase))
            throw new PhoneInputException("Enter your tenant address, for example company.openwebpbx.com.");
        var label = uri.Host[..^".openwebpbx.com".Length].ToLowerInvariant();
        if (!Label().IsMatch(label) || label.StartsWith("xn--", StringComparison.Ordinal) ||
            raw.Any(c => char.IsControl(c) || c > 127) || raw.Contains('\\') || raw.Contains('@') || raw.Contains('%'))
            throw new PhoneInputException("Use your tenant's openwebpbx.com address.");
        return new Uri("https://" + label + ".openwebpbx.com");
    }

    public static string Code(string value) => value is not null && SetupCode().IsMatch(value.Trim()) ? value.Trim() :
        throw new PhoneInputException("Ask your administrator for a new connection code.");
    public static string Extension(string value) => value is not null && ExtensionNumber().IsMatch(value.Trim()) ? value.Trim() :
        throw new PhoneInputException("Enter your extension number.");
    public static string Number(string value)
    {
        var number = value.Replace(" ", "").Replace("-", "").Replace("(", "").Replace(")", "");
        return DialString().IsMatch(number) ? number : throw new PhoneInputException("Enter a phone number or extension.");
    }
    public static void RequireIdle(int calls, bool installing = false)
    {
        if (calls != 0 || installing) throw new PhoneInputException("Finish your calls before changing accounts.");
    }
    public static void AppPassword(string value)
    {
        if (value.EnumerateRunes().Count() is < 12 or > 128 || value.Any(char.IsSurrogate) && !IsValidUtf16(value))
            throw new PhoneInputException("Use between 12 and 128 characters for your app password.");
    }
    private static bool IsValidUtf16(string value)
    {
        try { _ = new UnicodeEncoding(false, false, true).GetBytes(value); return true; }
        catch (EncoderFallbackException) { return false; }
    }
}

public sealed class PhoneInputException(string message) : Exception(message);

public sealed record SetupInvitation(Uri Server, string Code, string? Extension)
{
    public override string ToString() => "OpenWebPBX connection invitation for " + Server.Host;
    /// <summary>Read the opened file itself with a hard cap; its earlier metadata may be stale.</summary>
    public static async Task<SetupInvitation> ReadAsync(Stream input, CancellationToken cancellation = default)
    {
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation); bounded.CancelAfter(TimeSpan.FromSeconds(12));
        var bytes = new byte[ConnectionRules.MaximumSetupBytes + 1]; var total = 0;
        while (total < bytes.Length)
        {
            var count = await input.ReadAsync(bytes.AsMemory(total), bounded.Token); if (count == 0) break; total += count;
        }
        if (total > ConnectionRules.MaximumSetupBytes) throw new PhoneInputException("Choose a current OpenWebPBX setup file smaller than 16 KB.");
        return Parse(bytes.AsSpan(0, total));
    }
    public static SetupInvitation Parse(ReadOnlySpan<byte> data)
    {
        if (data.Length is 0 or > ConnectionRules.MaximumSetupBytes)
            throw new PhoneInputException("Choose an OpenWebPBX setup file or QR code.");
        try
        {
            using var json = JsonDocument.Parse(data.ToArray(), new JsonDocumentOptions { MaxDepth = 8 });
            var item = json.RootElement;
            if (item.ValueKind != JsonValueKind.Object) throw new JsonException();
            var fields = item.EnumerateObject().Select(x => x.Name).ToArray();
            if (fields.Distinct(StringComparer.Ordinal).Count() != fields.Length ||
                fields.Any(x => x is not ("type" or "version" or "server" or "code" or "extension")) ||
                item.GetProperty("type").GetString() != "openwebpbx" || item.GetProperty("version").GetInt32() != 1)
                throw new JsonException();
            return new SetupInvitation(ConnectionRules.Tenant(item.GetProperty("server").GetString()!),
                ConnectionRules.Code(item.GetProperty("code").GetString()!),
                item.TryGetProperty("extension", out var ext) ? ConnectionRules.Extension(ext.GetString()!) : null);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentNullException)
        { throw new PhoneInputException("Choose a current OpenWebPBX setup file. Setup files must not contain passwords."); }
    }

    public static SetupInvitation FromUri(Uri uri)
    {
        if (uri.Scheme != "openwebpbx" || uri.Host != "setup" || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath is not ("" or "/"))
            throw new PhoneInputException("Choose an OpenWebPBX connection link.");
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var pair = part.Split('=', 2); if (pair.Length != 2 || !fields.TryAdd(Uri.UnescapeDataString(pair[0]), Uri.UnescapeDataString(pair[1])))
                throw new PhoneInputException("This connection link is invalid.");
        }
        if (fields.Keys.Any(k => k is not ("server" or "code" or "extension")) || !fields.ContainsKey("server") || !fields.ContainsKey("code"))
            throw new PhoneInputException("This connection link is invalid.");
        return new SetupInvitation(ConnectionRules.Tenant(fields["server"]), ConnectionRules.Code(fields["code"]),
            fields.TryGetValue("extension", out var ext) ? ConnectionRules.Extension(ext) : null);
    }
}
