// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Text.Json;
using System.Security.Cryptography;
using System.Diagnostics;
using OpenWebPbx.Phone.Windows;
namespace OpenWebPbx.Phone.MediaChecks;
internal sealed record PeerInput(int Schema, string Root, string CaPem, string InputWav, string OutputWav, string StaticImage, string Realm, string Username, string Password, int Port, string Host = "127.0.0.1");
internal sealed record PeerCommand(int Sequence, string Action, string Number = "", Guid? Call = null, bool Video = false);
internal sealed record CallView(Guid Id, string Number, string State, bool Incoming);
internal sealed record PeerState(bool Ready, bool RegistrationFailed, bool Busy, bool Conferencing, Guid? Current, CallView[] Calls, NativeFixtureSnapshot Native, NativeLocalPlaybackSnapshot Playback);
internal sealed record PeerReply(int Sequence, string Stage, bool Ok, string ErrorType, PeerState? State);
internal static class Protocol
{
    internal static readonly JsonSerializerOptions Json = new() { MaxDepth = 8, PropertyNameCaseInsensitive = false };
    internal static string Hash(string path) { using var file = File.OpenRead(path); return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant(); }
    internal static void Own(Process process, string role, string journal, string expectedPath, DateTime expectedStart, string expectedHash)
    {
        ProcessImage.Require(process, expectedPath, expectedStart, expectedHash);
        var line = JsonSerializer.Serialize(new { role, pid = process.Id, created_utc_ticks = expectedStart.ToUniversalTime().Ticks, executable_sha256 = expectedHash }, Json) + "\n";
        using var file = new FileStream(journal, FileMode.Append, FileAccess.Write, FileShare.Read); var bytes = System.Text.Encoding.UTF8.GetBytes(line); file.Write(bytes); file.Flush(true);
    }
    internal static void NoLinks(string path)
    {
        var pending = new Stack<string>(); pending.Push(path); var count = 0;
        while (pending.TryPop(out var next)) { var attributes = File.GetAttributes(next); if ((attributes & FileAttributes.ReparsePoint) != 0 || ++count > 10000) throw new InvalidDataException("Bounded ordinary owned tree required."); if ((attributes & FileAttributes.Directory) != 0) foreach (var child in Directory.EnumerateFileSystemEntries(next)) pending.Push(child); }
    }
    internal static async Task Drain(StreamReader reader)
    {
        var chars = new char[4096]; long total = 0; int count;
        while ((count = await reader.ReadAsync(chars)) != 0) { total += count; if (total > 64 * 1024 * 1024) throw new InvalidDataException("Owned child output exceeded its private bound."); }
    }
    internal static async Task<(string Type, bool Observed)> PeerError(StreamReader reader)
    {
        var chars = new char[4096]; var text = new System.Text.StringBuilder(8192); long total = 0; int count;
        while ((count = await reader.ReadAsync(chars)) != 0) { total = checked(total + count); var keep = Math.Min(count, 8192 - text.Length); if (keep > 0) text.Append(chars, 0, keep); if (total > 64 * 1024 * 1024) throw new InvalidDataException("Owned child output exceeded its private bound."); }
        return FailureObservation.ReadPeerError(text.ToString(), total <= 8192);
    }
    internal static void Guard()
    {
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx") throw new InvalidOperationException("Only the disposable hosted Windows media lab is allowed.");
        if (Directory.Exists("C:/OpenWebPBX") || Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "OpenWebPBX"))) throw new InvalidOperationException("The media lab refuses an installed PBX.");
    }
    internal static string InputScope(string input, string prefix, string leaf)
    {
        var path = Path.GetFullPath(input); var parent = Path.GetDirectoryName(path)!; var temp = Path.GetFullPath(Environment.GetEnvironmentVariable("RUNNER_TEMP")!).TrimEnd(Path.DirectorySeparatorChar);
        if (!string.Equals(Path.GetDirectoryName(parent), temp, StringComparison.OrdinalIgnoreCase) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(parent), "^" + System.Text.RegularExpressions.Regex.Escape(prefix) + "[a-f0-9]{32}$") || Path.GetFileName(path) != leaf) throw new InvalidDataException("An exact owned fixture input path is required.");
        for (var directory = new DirectoryInfo(parent); directory is not null; directory = directory.Parent) if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Ordinary input ancestry required."); return parent;
    }
    internal static T Read<T>(string path, int maximum)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length is <= 0 || new FileInfo(path).Length > maximum) throw new InvalidDataException("Ordinary bounded fixture input required.");
        return JsonSerializer.Deserialize<T>(File.ReadAllBytes(path), Json) ?? throw new InvalidDataException("Fixture input missing.");
    }
    internal static void Write(string path, object value)
    {
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None); JsonSerializer.Serialize(output, value, Json); output.Flush(true);
    }
}
