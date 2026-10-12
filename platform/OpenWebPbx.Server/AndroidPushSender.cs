using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace OpenWebPbx.Server;

public enum PushDelivery { Sent, Unregistered, Expired }
public sealed class PushDeliveryException(TimeSpan retryAfter) : IOException("Notification delivery unavailable.")
{
    public TimeSpan RetryAfter { get; } = retryAfter;
}

public sealed class AndroidPushSender
{
    private readonly IHttpClientFactory clients;
    private readonly string settingsPath;
    private readonly Func<string,CancellationToken,Task<IPAddress[]>> resolve;
    private readonly SemaphoreSlim refresh = new(1, 1);
    private string? cachedToken, cachedIdentity;
    private DateTimeOffset tokenExpiry;
    public AndroidPushSender(IHttpClientFactory clients) : this(clients, ConfigPath) { }
    public AndroidPushSender(IHttpClientFactory clients, string settingsPath) : this(clients, settingsPath, Dns.GetHostAddressesAsync) { }
    public AndroidPushSender(IHttpClientFactory clients, string settingsPath, Func<string,CancellationToken,Task<IPAddress[]>> resolve) { this.clients = clients; this.settingsPath = settingsPath; this.resolve = resolve; }
    public static string ConfigPath => OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX", "mobile-push.json")
        : "/var/lib/openwebpbx/mobile-push.json";
    public JsonNode? Settings()
    {
        try
        {
            var file = new FileInfo(settingsPath);
            if (!file.Exists || file.Length > 65536 || file.LinkTarget is not null) return null;
            if (!OperatingSystem.IsWindows() && (File.GetUnixFileMode(settingsPath) & (UnixFileMode.GroupRead | UnixFileMode.GroupWrite | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherWrite | UnixFileMode.OtherExecute)) != 0) return null;
            var settings = JsonNode.Parse(File.ReadAllText(settingsPath));
            return settings?["enabled"]?.GetValue<bool>() == true ? settings : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException) { return null; }
    }
    private static string Base64(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static byte[] Decode(string value) => Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/').PadRight((value.Length+3)/4*4,'='));
    private static byte[] Public(ECParameters p) => [4,..p.Q.X!,..p.Q.Y!];
    public static byte[] EncryptWebPush(byte[] plain,byte[] publicKey,byte[] auth,ECParameters? ephemeral=null,byte[]? salt=null)
    {
        if(plain.Length>3072||publicKey.Length!=65||publicKey[0]!=4||auth.Length!=16)throw new InvalidDataException("Invalid notification subscription.");
        using var receiver=ECDiffieHellman.Create(new ECParameters { Curve=ECCurve.NamedCurves.nistP256,Q=new ECPoint { X=publicKey[1..33],Y=publicKey[33..65] } });
        using var sender=ephemeral is ECParameters key?ECDiffieHellman.Create(key):ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        var serverPublic=Public(sender.ExportParameters(false));var secret=sender.DeriveRawSecretAgreement(receiver.PublicKey);
        var authentication=HMACSHA256.HashData(auth,secret);
        var info=Encoding.ASCII.GetBytes("WebPush: info\0").Concat(publicKey).Concat(serverPublic).Append((byte)1).ToArray();
        var ikm=HMACSHA256.HashData(authentication,info);salt??=RandomNumberGenerator.GetBytes(16);if(salt.Length!=16)throw new InvalidDataException("Invalid notification salt.");
        var prk=HMACSHA256.HashData(salt,ikm);var cek=HMACSHA256.HashData(prk,Encoding.ASCII.GetBytes("Content-Encoding: aes128gcm\0\x01"))[..16];
        var nonce=HMACSHA256.HashData(prk,Encoding.ASCII.GetBytes("Content-Encoding: nonce\0\x01"))[..12];var record=plain.Append((byte)2).ToArray();
        var encrypted=new byte[record.Length];var tag=new byte[16];using var aes=new AesGcm(cek,16);aes.Encrypt(nonce,record,encrypted,tag);
        var header=new byte[21];salt.CopyTo(header,0);System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(16,4),4096);header[20]=65;
        CryptographicOperations.ZeroMemory(secret);CryptographicOperations.ZeroMemory(authentication);CryptographicOperations.ZeroMemory(ikm);CryptographicOperations.ZeroMemory(prk);CryptographicOperations.ZeroMemory(cek);
        return [..header,..serverPublic,..encrypted,..tag];
    }
    private static bool PublicAddress(IPAddress address)
    {
        if(address.IsIPv4MappedToIPv6)address=address.MapToIPv4();if(IPAddress.IsLoopback(address))return false;var b=address.GetAddressBytes();
        if(b.Length==4)return b[0]!=0&&b[0]!=10&&b[0]!=127&&b[0]<224&&!(b[0]==169&&b[1]==254)&&!(b[0]==172&&b[1]>=16&&b[1]<=31)&&!(b[0]==192&&b[1]==168)&&!(b[0]==100&&b[1]>=64&&b[1]<=127);
        return !address.Equals(IPAddress.IPv6Any)&&!address.IsIPv6LinkLocal&&!address.IsIPv6Multicast&&(b[0]&254)!=252;
    }
    private async Task<PushDelivery> WebPush(JsonNode config,string subscription,JsonObject data,Guid requestId,string kind,DateTimeOffset expires,CancellationToken ct)
    {
        if(subscription.Length>8192)throw new InvalidDataException("Invalid notification subscription.");var s=JsonNode.Parse(subscription)!;var endpoint=s["endpoint"]?.GetValue<string>()??"";
        if(!Regex.IsMatch(endpoint,"^https://fcm\\.googleapis\\.com/fcm/send/[A-Za-z0-9_:\\-.]{20,4000}$")||!Uri.TryCreate(endpoint,UriKind.Absolute,out var uri))throw new InvalidDataException("Invalid notification endpoint.");
        if(s["vapid_public_key"]?.GetValue<string>()!=config["vapid_public_key"]?.GetValue<string>())return PushDelivery.Expired;
        var addresses=await resolve(uri.Host,ct);if(addresses.Length==0||addresses.Any(a=>!PublicAddress(a)))throw new InvalidDataException("Notification endpoint unavailable.");
        using var vapid=ECDsa.Create();vapid.ImportFromPem(config["vapid_private_key"]!.GetValue<string>());var signingKey=Public(vapid.ExportParameters(false));
        if(signingKey.Length!=65||Base64(signingKey)!=config["vapid_public_key"]!.GetValue<string>())throw new InvalidDataException("Invalid notification identity.");
        var subject=config["vapid_subject"]?.GetValue<string>()??"mailto:hello@openwebpbx.com";
        if(subject.Length>256||!Uri.TryCreate(subject,UriKind.Absolute,out var contact)||contact.Scheme is not ("mailto" or "https"))throw new InvalidDataException("Invalid notification contact.");
        var header=Base64(Encoding.UTF8.GetBytes("{\"alg\":\"ES256\",\"typ\":\"JWT\"}"));
        var claims=Base64(Encoding.UTF8.GetBytes(new JsonObject { ["aud"]=uri.GetLeftPart(UriPartial.Authority),["exp"]=DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds(),["sub"]=subject }.ToJsonString()));
        var signing=header+"."+claims;var signature=Base64(vapid.SignData(Encoding.UTF8.GetBytes(signing),HashAlgorithmName.SHA256,DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
        var authorization="vapid t="+signing+"."+signature+", k="+Base64(signingKey);
        var encrypted=EncryptWebPush(Encoding.UTF8.GetBytes(data.ToJsonString()),Decode(s["p256dh"]!.GetValue<string>()),Decode(s["auth"]!.GetValue<string>()));
        if(expires<=DateTimeOffset.UtcNow)return PushDelivery.Expired;
        var ttl=Math.Clamp((int)Math.Floor((expires-DateTimeOffset.UtcNow).TotalSeconds),1,60);var relay=config["delivery"]?.GetValue<string>()=="cloudflare";
        using var request=new HttpRequestMessage(HttpMethod.Post,relay?config["relay_url"]!.GetValue<string>():endpoint);
        if(relay)
        {
            var relayKey=config["relay_token"]?.GetValue<string>()??"";
            if(!Regex.IsMatch(request.RequestUri!.AbsoluteUri,"^https://[a-z0-9-]+\\.[a-z0-9-]+\\.workers\\.dev/?$")||!Regex.IsMatch(relayKey,"^[A-Za-z0-9_-]{32,256}$"))throw new InvalidDataException("Invalid relay configuration.");
            request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",relayKey);
            request.Content=new StringContent(new JsonObject { ["transport"]="webpush",["endpoint"]=endpoint,["body"]=Base64(encrypted),["authorization"]=authorization,["ttl"]=ttl,["urgency"]=kind=="incoming"?"high":"normal" }.ToJsonString(),Encoding.UTF8,"application/json");
        }
        else
        {
            request.Headers.TryAddWithoutValidation("Authorization",authorization);request.Headers.Add("TTL",ttl.ToString(System.Globalization.CultureInfo.InvariantCulture));request.Headers.Add("Urgency",kind=="incoming"?"high":"normal");
            request.Content=new ByteArrayContent(encrypted);request.Content.Headers.ContentType=new MediaTypeHeaderValue("application/octet-stream");request.Content.Headers.ContentEncoding.Add("aes128gcm");
        }
        using var response=await clients.CreateClient("push").SendAsync(request,HttpCompletionOption.ResponseHeadersRead,ct);
        if(response.IsSuccessStatusCode)return PushDelivery.Sent;
        if(!relay&&response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone)return PushDelivery.Unregistered;
        var result=await Json(response,ct);if(relay&&response.StatusCode==HttpStatusCode.Gone&&result?["code"]?.GetValue<string>()=="UNREGISTERED")return PushDelivery.Unregistered;
        var delay=response.Headers.RetryAfter?.Delta??TimeSpan.FromSeconds(response.StatusCode==HttpStatusCode.TooManyRequests?60:3);throw new PushDeliveryException(TimeSpan.FromSeconds(Math.Clamp(delay.TotalSeconds,1,300)));
    }
    private static async Task<JsonNode?> Json(HttpResponseMessage response, CancellationToken ct)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var bytes = new MemoryStream(); var buffer = new byte[4096]; int read;
        while ((read = await stream.ReadAsync(buffer, ct)) > 0)
        {
            if (bytes.Length + read > 65536) throw new IOException("Notification response exceeds limit.");
            bytes.Write(buffer, 0, read);
        }
        try { return JsonNode.Parse(bytes.ToArray()); }
        catch (System.Text.Json.JsonException) { return null; }
    }
    private async Task<string> AccessToken(JsonNode account, string project, CancellationToken ct)
    {
        var email = account["client_email"]?.GetValue<string>() ?? ""; var pem = account["private_key"]?.GetValue<string>() ?? "";
        if (account["type"]?.GetValue<string>() != "service_account" || account["project_id"]?.GetValue<string>() != project || !Regex.IsMatch(email, "^[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+\\.iam\\.gserviceaccount\\.com$") || pem.Length > 32768) throw new InvalidDataException("Invalid notification account.");
        var identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(email + "\n" + project + "\n" + pem)));
        await refresh.WaitAsync(ct);
        try
        {
            if (cachedIdentity == identity && cachedToken is not null && tokenExpiry > DateTimeOffset.UtcNow.AddMinutes(2)) return cachedToken;
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var header = Base64(Encoding.UTF8.GetBytes("{\"alg\":\"RS256\",\"typ\":\"JWT\"}"));
            var payload = Base64(Encoding.UTF8.GetBytes(new JsonObject { ["iss"] = email, ["scope"] = "https://www.googleapis.com/auth/firebase.messaging", ["aud"] = "https://oauth2.googleapis.com/token", ["iat"] = now, ["exp"] = now + 3600 }.ToJsonString()));
            using var rsa = RSA.Create(); rsa.ImportFromPem(pem); if (rsa.KeySize < 2048) throw new InvalidDataException("Invalid notification key.");
            var signing = header + "." + payload;
            var jwt = signing + "." + Base64(rsa.SignData(Encoding.UTF8.GetBytes(signing), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://oauth2.googleapis.com/token") { Content = new FormUrlEncodedContent(new Dictionary<string, string> { ["grant_type"] = "urn:ietf:params:oauth:grant-type:jwt-bearer", ["assertion"] = jwt }) };
            using var reply = await clients.CreateClient("push").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            var result = await Json(reply, ct);
            if (!reply.IsSuccessStatusCode || result?["access_token"] is null) throw new IOException("Notification authentication unavailable.");
            var token = result["access_token"]!.GetValue<string>(); var seconds = result["expires_in"]?.GetValue<int>() ?? 3600;
            if (token.Length is < 10 or > 8192 || token.Any(c => c <= 32 || c >= 127) || seconds <= 0) throw new IOException("Notification authentication unavailable.");
            cachedToken = token; cachedIdentity = identity; tokenExpiry = DateTimeOffset.UtcNow.AddSeconds(Math.Min(seconds, 3600)); return token;
        }
        finally { refresh.Release(); }
    }
    public async Task<PushDelivery> Send(JsonNode config, string token, Guid requestId, string deviceId, string kind, DateTimeOffset expires, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(12)); var bounded = deadline.Token;
        var project = config["project_id"]?.GetValue<string>() ?? ""; var mode = config["delivery"]?.GetValue<string>() ?? "direct";
        if (!Regex.IsMatch(project, "^[a-z][a-z0-9-]{4,62}$") || !Guid.TryParse(deviceId, out var device) || kind is not ("incoming" or "ended") || expires > DateTimeOffset.UtcNow.AddSeconds(120)) throw new InvalidDataException("Invalid notification request.");
        if (expires <= DateTimeOffset.UtcNow) return PushDelivery.Expired;
        var data = new JsonObject { ["request_id"] = requestId.ToString(), ["device_id"] = device.ToString(), ["event"] = kind, ["expires"] = expires.ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture) };
        if(config["provider"]?.GetValue<string>()=="webpush")return await WebPush(config,token,data,requestId,kind,expires,bounded);
        if(!Regex.IsMatch(token,"^[a-zA-Z0-9_:\\-.]{20,4096}$"))throw new InvalidDataException("Invalid notification token.");
        using var request = new HttpRequestMessage(HttpMethod.Post, mode == "cloudflare" ? config["relay_url"]!.GetValue<string>() : $"https://fcm.googleapis.com/v1/projects/{project}/messages:send");
        JsonObject payload;
        if (mode == "cloudflare")
        {
            var relayKey = config["relay_token"]?.GetValue<string>() ?? "";
            if (!Regex.IsMatch(request.RequestUri!.AbsoluteUri, "^https://[a-z0-9-]+\\.[a-z0-9-]+\\.workers\\.dev/?$") || !Regex.IsMatch(relayKey, "^[A-Za-z0-9_-]{32,256}$")) throw new InvalidDataException("Invalid relay configuration.");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", relayKey); payload = new JsonObject { ["project_id"] = project, ["token"] = token, ["data"] = data };
        }
        else if (mode == "direct")
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await AccessToken(config["service_account"]!, project, bounded));
            if (expires <= DateTimeOffset.UtcNow) return PushDelivery.Expired;
            var ttl = Math.Clamp((int)Math.Floor((expires - DateTimeOffset.UtcNow).TotalSeconds), 1, 30);
            payload = new JsonObject { ["message"] = new JsonObject { ["token"] = token, ["data"] = data, ["android"] = new JsonObject { ["priority"] = kind == "incoming" ? "high" : "normal", ["ttl"] = ttl + "s", ["collapse_key"] = requestId.ToString() } } };
        }
        else throw new InvalidDataException("Invalid notification delivery method.");
        request.Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json");
        using var response = await clients.CreateClient("push").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, bounded);
        var body = await Json(response, bounded);
        if (response.IsSuccessStatusCode) return PushDelivery.Sent;
        if (mode == "cloudflare")
        {
            if (response.StatusCode == HttpStatusCode.Gone && body?["code"]?.GetValue<string>() == "UNREGISTERED") return PushDelivery.Unregistered;
            if (response.StatusCode == HttpStatusCode.Gone && body?["code"]?.GetValue<string>() == "CALL_EXPIRED") return PushDelivery.Expired;
        }
        else if (response.StatusCode == HttpStatusCode.NotFound && body?["error"]?["details"] is JsonArray details
            && details.Any(d => d?["@type"]?.GetValue<string>() == "type.googleapis.com/google.firebase.fcm.v1.FcmError" && d?["errorCode"]?.GetValue<string>() == "UNREGISTERED")) return PushDelivery.Unregistered;
        // A missing project, permission error, quota failure or malformed response
        // must never erase a valid device's registration token.
        var retry = response.Headers.RetryAfter?.Delta ?? (response.Headers.RetryAfter?.Date - DateTimeOffset.UtcNow) ?? TimeSpan.FromSeconds(3);
        if (response.StatusCode == HttpStatusCode.TooManyRequests) retry = retry < TimeSpan.FromMinutes(1) ? TimeSpan.FromMinutes(1) : retry;
        throw new PushDeliveryException(TimeSpan.FromSeconds(Math.Clamp(retry.TotalSeconds, 1, 300)));
    }
}
