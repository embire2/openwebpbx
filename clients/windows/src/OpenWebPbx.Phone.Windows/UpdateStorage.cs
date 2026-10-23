// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
using System.Text.Json;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
public sealed class UpdateStorage
{
    private readonly string path;
    public string Directory { get; }
    public UpdateStorage(string channel) : this(channel, null) { }
    internal UpdateStorage(string channel, string? isolatedRoot)
    {
        if (channel is not ("direct" or "store")) throw new ArgumentException();
        var parent = StoragePaths.Channel(channel);
        if (isolatedRoot is not null)
        {
            var runner = Environment.GetEnvironmentVariable("RUNNER_TEMP"); var value = Path.GetFullPath(isolatedRoot);
            if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("GITHUB_REPOSITORY") != "embire2/openwebpbx" || runner is null || !Path.GetDirectoryName(value)!.Equals(Path.GetFullPath(runner).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase) || !System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(value), "^phone-native-[a-f0-9]{32}$")) throw new InvalidOperationException("Update fixture root differs.");
            parent = value;
        }
        if (!System.IO.Directory.Exists(parent)) throw new PhoneInputException("Open your accounts before checking for updates.");
        Directory = Path.Combine(parent, "updates");
        for (var item = new DirectoryInfo(Directory); item is not null; item = item.Parent) if (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0) throw new PhoneInputException("The private update cache is linked.");
        System.IO.Directory.CreateDirectory(Directory); path = Path.Combine(Directory, "accepted.dpapi");
    }
    public ClientTrustState Read()
    {
        try
        {
            if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0 || new FileInfo(path).Length > 16384) throw Invalid();
            var bytes = Dpapi.Unprotect(File.ReadAllBytes(path));
            try { var value = JsonSerializer.Deserialize<ClientTrustState>(bytes) ?? throw Invalid(); if (value.Sequence < 1 || value.PayloadSha256.Length != 64 || value.PayloadSha256.Any(c => !char.IsAsciiHexDigit(c))) throw Invalid(); return value; }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        catch (FileNotFoundException) { return new(); }
        catch (JsonException) { throw Invalid(); }
    }
    public void Accept(ClientRelease release)
    {
        var next = Read().Advance(release); var data = JsonSerializer.SerializeToUtf8Bytes(next); byte[] encrypted;
        try { encrypted = Dpapi.Protect(data); } finally { CryptographicOperations.ZeroMemory(data); }
        var temporary = Path.Combine(Directory, Guid.NewGuid().ToString("N") + ".tmp");
        try { using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) { file.Write(encrypted); file.Flush(true); } File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static UpdateStorage ForPackage(string family, string channel)
    {
        if (channel is not ("direct" or "store")) throw new ArgumentException();
        return new UpdateStorage(new DirectoryInfo(Path.Combine(StoragePaths.ForPackage(family), channel)));
    }
    private UpdateStorage(DirectoryInfo installedDirectory)
    {
        var installedParent = installedDirectory.FullName;
        if (!System.IO.Directory.Exists(installedParent)) throw Invalid();
        Directory = Path.Combine(installedParent, "updates");
        for (var item = new DirectoryInfo(Directory); item is not null; item = item.Parent) if (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0) throw Invalid();
        if (!System.IO.Directory.Exists(Directory)) throw Invalid(); path = Path.Combine(Directory, "accepted.dpapi");
    }
    private static PhoneInputException Invalid() => new("Your saved Windows update trust could not be opened. The current phone has been kept.");
}
