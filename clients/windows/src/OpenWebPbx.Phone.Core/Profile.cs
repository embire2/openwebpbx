// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json.Nodes;

namespace OpenWebPbx.Phone.Core;

public sealed record SipAccount(string Server, string Realm, string Username, string AuthUsername, string Password, int Port)
{
    public override string ToString() => "Protected SIP account";
}
public sealed record AccountIdentity(Guid DomainId, Guid ExtensionId, string Extension, string TenantName, string DisplayName);
public sealed record PhoneProfile(Guid Id, Uri Server, string Token, Guid DeviceId, SipAccount Sip, AccountIdentity Account,
    string[] Features, string Name = "", bool NeedsLogin = false)
{
    public string Label => string.IsNullOrWhiteSpace(Name) ? $"{Account.TenantName} · {Account.Extension}" : Name;
    public override string ToString() => Label;
    public bool SameAccount(PhoneProfile other) => Server == other.Server &&
        ((Account.DomainId == other.Account.DomainId && Account.ExtensionId == other.Account.ExtensionId) ||
         (Sip.Realm.Equals(other.Sip.Realm, StringComparison.OrdinalIgnoreCase) && Account.Extension == other.Account.Extension));

    public static PhoneProfile FromConnection(JsonObject response, Uri approvedServer, Guid expectedDomain)
    {
        try
        {
            var server = ConnectionRules.Tenant(approvedServer.AbsoluteUri);
            var sip = response["sip"]!.AsObject(); var account = response["account"]!.AsObject();
            string Text(JsonObject o, string key) => o[key]?.GetValue<string>() is { Length: > 0 } s && !s.Any(char.IsControl) ? s : throw new FormatException();
            var token = Text(response, "token"); if (token.Length != 64 || token.Any(c => !Uri.IsHexDigit(c))) throw new FormatException();
            var domain = Guid.Parse(Text(account, "domain_uuid")); if (domain == Guid.Empty || domain != expectedDomain) throw new FormatException();
            var extension = Guid.Parse(Text(account, "extension_uuid")); var device = Guid.Parse(Text(response, "device_id"));
            if (extension == Guid.Empty || device == Guid.Empty || Text(sip, "transport") != "tls" || Text(sip, "media_encryption") != "srtp") throw new FormatException();
            var port = sip["port"]?.GetValue<int>() ?? 5061; if (port is < 1 or > 65535) throw new FormatException();
            var host = Text(sip, "server"); if (Uri.CheckHostName(host) == UriHostNameType.Unknown) throw new FormatException();
            var username = Text(sip, "username");
            return new PhoneProfile(Guid.NewGuid(), server, token, device,
                new SipAccount(host, Text(sip, "domain"), username, sip["auth_username"]?.GetValue<string>() ?? username, Text(sip, "password"), port),
                new AccountIdentity(domain, extension, ConnectionRules.Extension(Text(account, "extension")),
                    account["tenant_name"]?.GetValue<string>() ?? server.Host, account["display_name"]?.GetValue<string>() ?? ""),
                response["features"]?.AsArray().Select(x => x!.GetValue<string>()).ToArray() ?? []);
        }
        catch (Exception e) when (e is FormatException or InvalidOperationException or NullReferenceException or ArgumentException)
        { throw new PhoneInputException("The PBX returned an incomplete or different phone account. Ask your administrator to check it."); }
    }
}

public interface IProfileStore
{
    Task<IReadOnlyList<PhoneProfile>> ReadAsync(CancellationToken cancellation = default);
    Task<Guid?> SelectedAsync(CancellationToken cancellation = default);
    Task SaveAsync(IReadOnlyList<PhoneProfile> profiles, Guid? selected, CancellationToken cancellation = default);
}
