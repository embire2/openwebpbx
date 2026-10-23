// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json.Nodes;
namespace OpenWebPbx.Phone.Core;

public sealed record TenantProof(string Hostname, Guid DomainId, long Revision);
public sealed class TenantRegistry(HttpMessageHandler? handler = null, TimeSpan? requestDeadline = null) : IDisposable
{
    private readonly HttpClient client = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }, true) { Timeout = TimeSpan.FromSeconds(12) };
    public async Task<TenantProof> LookupAsync(Uri tenant, CancellationToken cancellation = default)
    {
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var deadline = requestDeadline ?? TimeSpan.FromSeconds(12); if (deadline <= TimeSpan.Zero || deadline > TimeSpan.FromSeconds(12)) throw new ArgumentOutOfRangeException(nameof(requestDeadline));
        bounded.CancelAfter(deadline); cancellation = bounded.Token;
        var host = ConnectionRules.Tenant(tenant.AbsoluteUri).Host;
        using var response = await client.GetAsync("https://domains.openwebpbx.com/v1/tenant-addresses/" + host, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength > 4096) throw Missing();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellation); var bytes = new byte[4097]; var total = 0;
        while (total < bytes.Length) { var n = await stream.ReadAsync(bytes.AsMemory(total), cancellation); if (n == 0) break; total += n; }
        if (total is 0 or > 4096) throw Missing();
        try
        {
            var value = JsonNode.Parse(bytes.AsSpan(0, total))!.AsObject();
            if (value["schema"]!.GetValue<int>() != 1 || value["hostname"]!.GetValue<string>() != host || value["revision"]!.GetValue<long>() < 1 ||
                !Guid.TryParse(value["domainUuid"]!.GetValue<string>(), out var domain) || domain == Guid.Empty) throw Missing();
            var origin = new Uri(value["serverOrigin"]!.GetValue<string>());
            if (origin.Scheme != "https" || origin.Port != 443 || origin.UserInfo != "" || origin.Query != "" || origin.Fragment != "" || origin.AbsolutePath != "/") throw Missing();
            return new(host, domain, value["revision"]!.GetValue<long>());
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException or NullReferenceException or FormatException or ArgumentException) { throw Missing(); }
    }
    private static PhoneInputException Missing() => new("This tenant address is not ready. Check it with your administrator and try again.");
    public void Dispose() => client.Dispose();
}

/// <summary>Connection codes are consumed only by the tenant; failure after enrollment revokes the newly created device.</summary>
public sealed class ConnectionService(ProfileManager profiles, Func<bool> idle)
{
    public async Task<PhoneProfile> LoginAsync(string tenant, string extension, string password, string deviceName, CancellationToken cancellation = default, Guid? reconnectId = null)
    {
        if (string.IsNullOrEmpty(password) || password.Length > 1024) throw new PhoneInputException("Enter your app password.");
        return await Connect(tenant, "login", new() { ["extension"] = ConnectionRules.Extension(extension), ["password"] = password }, deviceName, cancellation, reconnectId);
    }
    public Task<PhoneProfile> EnrollAsync(SetupInvitation invitation, string deviceName, CancellationToken cancellation = default) => Connect(invitation.Server.AbsoluteUri, "enroll", new() { ["code"] = invitation.Code }, deviceName, cancellation);
    private async Task<PhoneProfile> Connect(string tenant, string action, JsonObject body, string deviceName, CancellationToken cancellation, Guid? reconnectId = null)
    {
        ConnectionRules.RequireIdle(idle() ? 0 : 1, false); var origin = ConnectionRules.Tenant(tenant);
        using var registry = new TenantRegistry(); var proof = await registry.LookupAsync(origin, cancellation);
        using var api = new PhoneApi(origin);
        var capabilities = await api.JsonAsync("capabilities", cancellation: cancellation);
        if (capabilities["windows_phone"]?.GetValue<bool>() != true) throw new PhoneInputException("Your PBX needs the Windows Free Phone update. Ask your instance administrator to install it.");
        if (action == "login" && capabilities["app_password"]?.GetValue<bool>() != true) throw new PhoneInputException("App-password sign-in needs an updated PBX. Use your administrator’s setup file or QR code.");
        body["device_name"] = string.IsNullOrWhiteSpace(deviceName) ? "Windows Free Phone" : new string(deviceName.Where(c => !char.IsControl(c)).Take(80).ToArray()); body["platform"] = "windows";
        var result = await api.JsonAsync(action, body, cancellation: cancellation);
        var profile = PhoneProfile.FromConnection(result, origin, proof.DomainId);
        try { ConnectionRules.RequireIdle(idle() ? 0 : 1, false); if (reconnectId is Guid id) { await profiles.ReconnectAsync(id, profile, cancellation); return profile with { Id = id }; } await profiles.AddAsync(profile, cancellation); return profile; }
        catch
        {
            try { using var rollback = new PhoneApi(origin, profile.Token); await rollback.JsonAsync("revoke", new(), cancellation: CancellationToken.None); } catch { /* Newly issued device expires; no credentials are logged. */ }
            throw;
        }
    }
}
