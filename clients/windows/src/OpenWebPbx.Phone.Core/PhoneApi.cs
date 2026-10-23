// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;

namespace OpenWebPbx.Phone.Core;

public sealed class PhoneApi : IDisposable
{
    private readonly HttpClient client;
    private readonly Uri origin;
    private readonly string? token;
    private readonly TimeSpan deadline;
    public PhoneApi(Uri tenant, string? token = null, HttpMessageHandler? handler = null, TimeSpan? requestDeadline = null)
    {
        origin = ConnectionRules.Tenant(tenant.AbsoluteUri); this.token = token;
        deadline = requestDeadline ?? TimeSpan.FromSeconds(12); if (deadline <= TimeSpan.Zero || deadline > TimeSpan.FromSeconds(12)) throw new ArgumentOutOfRangeException(nameof(requestDeadline));
        client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }, true)
        { Timeout = TimeSpan.FromSeconds(12) };
    }
    public async Task<JsonObject> JsonAsync(string action, JsonObject? body = null, string? id = null, CancellationToken cancellation = default)
    {
        var bytes = await BytesAsync(action, body, id, 2 * 1024 * 1024, cancellation);
        try { return JsonNode.Parse(bytes, documentOptions: new() { MaxDepth = 32 })!.AsObject(); }
        catch (Exception e) when (e is System.Text.Json.JsonException or InvalidOperationException or NullReferenceException)
        { throw new PhoneInputException("The PBX returned an unreadable response. Try again shortly."); }
    }
    public Task<byte[]> VoicemailAsync(string id, CancellationToken cancellation = default) => BytesAsync("voicemail_audio", null, id, 32 * 1024 * 1024, cancellation);
    private async Task<byte[]> BytesAsync(string action, JsonObject? body, string? id, int maximum, CancellationToken cancellation)
    {
        using var bounded = CancellationTokenSource.CreateLinkedTokenSource(cancellation); bounded.CancelAfter(deadline); cancellation = bounded.Token;
        if (action.Length is 0 or > 40 || action.Any(c => c is not (>= 'a' and <= 'z') and not '_')) throw new ArgumentException("Invalid phone action.", nameof(action));
        var target = new Uri(origin, "/app/pbx_mobile/api.php?action=" + action + (id is null ? "" : "&id=" + Uri.EscapeDataString(id)));
        using var request = new HttpRequestMessage(body is null ? HttpMethod.Get : HttpMethod.Post, target);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.UserAgent.ParseAdd("OpenWebPBX-WindowsPhone/1.0.0");
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = new StringContent(body.ToJsonString(), System.Text.Encoding.UTF8, "application/json");
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode) throw new PhoneApiException(response.StatusCode, action);
        if (response.Content.Headers.ContentLength > maximum) throw new PhoneInputException("The PBX returned a file that is too large.");
        await using var input = await response.Content.ReadAsStreamAsync(cancellation); using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var read = await input.ReadAsync(buffer, cancellation); if (read == 0) break;
            if (output.Length + read > maximum) throw new PhoneInputException("The PBX returned too much data.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }
    public void Dispose() => client.Dispose();
}

public sealed class PhoneApiException(HttpStatusCode status, string action) : Exception(Friendly(status, action))
{
    public HttpStatusCode Status { get; } = status;
    private static string Friendly(HttpStatusCode status, string action) => (int)status switch
    {
        401 or 403 => action == "login" ? "Check your tenant, extension and app password." : action == "change_password" ? "Your current app password is incorrect." : "This account needs to sign in again.",
        409 or 410 => "That connection code was already used or has expired.",
        429 => "Please wait a moment before trying again.",
        503 => "Your PBX is temporarily unavailable. Try again shortly.",
        _ => "The PBX could not complete the request. Please try again."
    };
}
