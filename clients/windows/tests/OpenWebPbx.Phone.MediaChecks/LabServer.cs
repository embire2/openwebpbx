// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
namespace OpenWebPbx.Phone.MediaChecks;

// This starts a console engine in one owned temporary directory. It never installs
// a service, imports a certificate, accesses a PBX database or uses a provider.
internal sealed class LabServer : IDisposable
{
    private readonly string root, executable, journal; private Process? process; private DateTime started;
    private Task? stdout, stderr; private TcpClient? socket; private NetworkStream? stream; private StreamReader? reader;
    private readonly string secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    private readonly int eventPort = FreePort(), sipPort = FreePort(); private bool disposed;
    public int TlsPort { get; } = FreePort();
    public string Realm { get; } = "media-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant() + ".invalid";
    public string Password { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    public string CaPem { get; }
    public string WrongCaPem { get; }
    public int ProcessId => process?.Id ?? throw new InvalidOperationException();
    internal LabServer(string ownerRoot, string engineRoot, string processJournal)
    {
        journal = processJournal;
        root = Path.Combine(ownerRoot, "engine"); LabCoordinator.PrivateDirectory(root);
        foreach (var part in new[] { "conf/autoload_configs", "mod", "db", "log", "run", "sounds", "tls" }) Directory.CreateDirectory(Path.Combine(root, part));
        foreach (var file in Directory.EnumerateFiles(engineRoot, "*", SearchOption.TopDirectoryOnly))
            if (Path.GetExtension(file) is ".dll" or ".exe") Copy(file, Path.Combine(root, Path.GetFileName(file)));
        foreach (var name in Modules) Copy(Path.Combine(engineRoot, "mod", name + ".dll"), Path.Combine(root, "mod", name + ".dll"));
        executable = Path.Combine(root, "FreeSwitchConsole.exe");
        if (Protocol.Hash(Path.Combine(root, "FreeSwitch.dll")) != "8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726" || Protocol.Hash(Path.Combine(root, "pthread.dll")) != "2d9d70378f13dcc06eed72005e74a12c6f7ba085e5fd31f97be49b7ef87cfdad" || Protocol.Hash(Path.Combine(root, "mod/mod_sofia.dll")) != "fa58601adfab5cd71ac598035c41fafe335f23f0ca038cb0b5c23423ff43d4d5") throw new InvalidDataException("Accepted engine bytes differ.");
        using var caKey = RSA.Create(2048); var caRequest = new CertificateRequest("CN=Owned media lab CA", caKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        caRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true)); caRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
        using var ca = caRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-10), DateTimeOffset.UtcNow.AddDays(1)); CaPem = ca.ExportCertificatePem();
        using var otherKey = RSA.Create(2048); var otherRequest = new CertificateRequest("CN=Untrusted owned CA", otherKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1); otherRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true)); using var other = otherRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-10), DateTimeOffset.UtcNow.AddDays(1)); WrongCaPem = other.ExportCertificatePem();
        using var key = RSA.Create(2048); var request = new CertificateRequest("CN=127.0.0.1", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1); var san = new SubjectAlternativeNameBuilder(); san.AddIpAddress(IPAddress.Loopback); request.CertificateExtensions.Add(san.Build()); request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true)); request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true)); request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], true));
        using var leaf = request.Create(ca, DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddHours(12), RandomNumberGenerator.GetBytes(16));
        File.WriteAllText(Path.Combine(root, "tls/agent.pem"), leaf.ExportCertificatePem() + "\n" + key.ExportPkcs8PrivateKeyPem(), new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(root, "tls/cafile.pem"), CaPem, new UTF8Encoding(false));
        PcmWave.Write(Path.Combine(root, "sounds/hold.wav"), [1553]); WriteConfiguration();
    }
    private static readonly string[] Modules = ["mod_console", "mod_logfile", "mod_commands", "mod_sofia", "mod_event_socket", "mod_dptools", "mod_dialplan_xml", "mod_sndfile", "mod_tone_stream", "mod_conference"];
    private static void Copy(string from, string to) { if ((File.GetAttributes(from) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw new InvalidDataException("Ordinary accepted engine input required."); File.Copy(from, to, false); }
    private static int FreePort() { var socket = new TcpListener(IPAddress.Loopback, 0); try { socket.Start(); return ((IPEndPoint)socket.LocalEndpoint).Port; } finally { socket.Stop(); } }
    private static XElement Param(string name, object value) => new("param", new XAttribute("name", name), new XAttribute("value", value));
    private void Config(string name, XElement content) => new XDocument(new XElement("configuration", new XAttribute("name", name), content)).Save(Path.Combine(root, "conf/autoload_configs", name + ".xml"));
    private void WriteConfiguration()
    {
        Config("modules.conf", new XElement("modules", Modules.Select(name => new XElement("load", new XAttribute("module", name)))));
        Config("switch.conf", new XElement("settings", Param("rtp-start-port", 39000), Param("rtp-end-port", 39200), Param("max-sessions", 16), Param("sessions-per-second", 8)));
        Config("console.conf", new XElement("mappings", new XElement("map", new XAttribute("name", "all"), new XAttribute("value", "warning"))));
        Config("logfile.conf", new XElement("profiles", new XElement("profile", new XAttribute("name", "default"), new XElement("settings", Param("rollover", 1048576)), new XElement("mappings", new XElement("map", new XAttribute("name", "all"), new XAttribute("value", "warning"))))));
        Config("event_socket.conf", new XElement("settings", Param("listen-ip", "127.0.0.1"), Param("listen-port", eventPort), Param("password", secret), Param("nat-map", false)));
        var settings = new XElement("settings", Param("sip-ip", "127.0.0.1"), Param("rtp-ip", "127.0.0.1"), Param("ext-sip-ip", "127.0.0.1"), Param("ext-rtp-ip", "127.0.0.1"), Param("sip-port", sipPort), Param("tls", true), Param("tls-only", true), Param("tls-sip-port", TlsPort), Param("tls-cert-dir", Path.Combine(root, "tls")), Param("tls-bind-params", "transport=tls"), Param("tls-version", "tlsv1.2"), Param("tls-verify-policy", "none"), Param("context", "media"), Param("dialplan", "XML"), Param("auth-calls", true), Param("challenge-realm", Realm), Param("inbound-codec-prefs", "PCMU,PCMA,VP8"), Param("outbound-codec-prefs", "PCMU,PCMA,VP8"), Param("inbound-proxy-media", false), Param("disable-transcoding", false), Param("inbound-late-negotiation", true), Param("manage-presence", false));
        Config("sofia.conf", new XElement("profiles", new XElement("profile", new XAttribute("name", "media"), new XElement("domains"), settings)));
        var users = Enumerable.Range(1, 3).Select(i => new XElement("user", new XAttribute("id", "810" + i), new XElement("params", Param("password", Password)), new XElement("variables", new XElement("variable", new XAttribute("name", "user_context"), new XAttribute("value", "media")))));
        var directory = new XElement("section", new XAttribute("name", "directory"), new XElement("domain", new XAttribute("name", Realm), new XElement("params", Param("dial-string", "{presence_id=${dialed_user}@${dialed_domain}}${sofia_contact(media/${dialed_user}@${dialed_domain})}")), new XElement("groups", new XElement("group", new XAttribute("name", "default"), new XElement("users", users)))));
        XElement Action(string app, string data) => new("action", new XAttribute("application", app), new XAttribute("data", data));
        var route = new XElement("extension", new XAttribute("name", "only-owned-phones"), new XElement("condition", new XAttribute("field", "destination_number"), new XAttribute("expression", "^(810[123])$"), Action("set", "hangup_after_bridge=true"), Action("set", "call_timeout=15"), Action("set", "rtp_secure_media=mandatory:AES_CM_128_HMAC_SHA1_80"), Action("set", "hold_music=" + Path.Combine(root, "sounds/hold.wav").Replace('\\', '/')), Action("export", "nolocal:hold_music=" + Path.Combine(root, "sounds/hold.wav").Replace('\\', '/')), Action("bridge", "user/$1@" + Realm)));
        var doc = new XDocument(new XElement("document", new XAttribute("type", "freeswitch/xml"), new XElement("section", new XAttribute("name", "configuration"), new XElement("X-PRE-PROCESS", new XAttribute("cmd", "include"), new XAttribute("data", "autoload_configs/*.xml"))), directory, new XElement("section", new XAttribute("name", "dialplan"), new XElement("context", new XAttribute("name", "media"), route))));
        doc.Save(Path.Combine(root, "conf/freeswitch.xml"));
    }
    internal void Start()
    {
        var info = new ProcessStartInfo(executable) { WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "-nonat", "-nort", "-base", root, "-conf", Path.Combine(root, "conf"), "-mod", Path.Combine(root, "mod"), "-db", Path.Combine(root, "db"), "-log", Path.Combine(root, "log"), "-run", Path.Combine(root, "run") }) info.ArgumentList.Add(arg);
        process = Process.Start(info) ?? throw new InvalidOperationException(); started = process.StartTime.ToUniversalTime(); stdout = Protocol.Drain(process.StandardOutput); stderr = Protocol.Drain(process.StandardError);
        Protocol.Own(process, "engine", journal);
        var clock = Stopwatch.StartNew();
        while (clock.Elapsed.TotalSeconds < 25 && !process.HasExited)
        {
            try { socket = new TcpClient(); socket.Connect(IPAddress.Loopback, eventPort); break; }
            catch (SocketException) { socket?.Dispose(); socket = null; Thread.Sleep(100); }
        }
        if (socket is null) throw new InvalidOperationException("Owned console engine did not start.");
        socket.ReceiveTimeout = 5000; socket.SendTimeout = 5000; stream = socket.GetStream(); stream.ReadTimeout = 5000; stream.WriteTimeout = 5000; reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
        if (Frame().Headers.GetValueOrDefault("content-type") != "auth/request") throw new InvalidDataException("Owned ESL greeting differs."); Send("auth " + secret); if (Frame().Headers.GetValueOrDefault("reply-text") != "+OK accepted") throw new InvalidDataException("Owned ESL authentication failed.");
        foreach (var module in Modules) if (Api("module_exists " + module).Trim() != "true") throw new InvalidDataException("Required actual engine module missing.");
        CoreCodecInventory.Require(Api("show codecs as json"));
        var status = Api("sofia status profile media"); if (!System.Text.RegularExpressions.Regex.IsMatch(status, @"(?m)^SIP-IP\s+127\.0\.0\.1\s*$") || !status.Contains(TlsPort.ToString(), StringComparison.Ordinal)) throw new InvalidDataException("Loopback TLS profile not proven.");
    }
    private void Send(string text) { if (text.Length > 256 || text.Any(c => c is '\n' or '\r')) throw new InvalidDataException(); var data = Encoding.ASCII.GetBytes(text + "\n\n"); stream!.Write(data); }
    private (Dictionary<string, string> Headers, string Body) Frame()
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); var size = 0;
        while (true) { var line = reader!.ReadLine() ?? throw new EndOfStreamException(); size += line.Length; if (size > 8192 || line.Length > 4096) throw new InvalidDataException("Bounded ESL headers required."); if (line.Length == 0) break; var split = line.IndexOf(':'); if (split <= 0 || !headers.TryAdd(line[..split].Trim(), line[(split + 1)..].Trim())) throw new InvalidDataException("Unique ESL headers required."); }
        var body = ""; if (headers.TryGetValue("Content-Length", out var raw)) { if (!int.TryParse(raw, out var count) || count is < 0 or > 1048576) throw new InvalidDataException("Bounded ESL body required."); var chars = new char[count]; var at = 0; while (at < count) { var read = reader!.Read(chars, at, count - at); if (read == 0) throw new EndOfStreamException(); at += read; } body = new string(chars); } return (headers, body);
    }
    private string Api(string text) { Send("api " + text); return Frame().Body; }
    internal void RequireIdle()
    {
        var clock = Stopwatch.StartNew(); while (clock.Elapsed.TotalSeconds < 10) { if (Api("show channels count").Trim() == "0 total.") return; Thread.Sleep(100); } throw new InvalidDataException("Owned engine channels did not drain.");
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        try { if (process is not null && !process.HasExited) { RequireIdle(); Send("api shutdown"); if (!process.WaitForExit(12000) || process.ExitCode != 0) throw new InvalidDataException("Owned engine clean shutdown failed."); } }
        finally
        {
            reader?.Dispose(); stream?.Dispose(); socket?.Dispose();
            if (process is not null) { if (!process.HasExited) { if (process.StartTime.ToUniversalTime() != started || !string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Owned engine identity differs."); process.Kill(true); if (!process.WaitForExit(10000)) throw new TimeoutException("Owned engine termination failed."); } stdout?.GetAwaiter().GetResult(); stderr?.GetAwaiter().GetResult(); process.Dispose(); }
        }
    }
}
