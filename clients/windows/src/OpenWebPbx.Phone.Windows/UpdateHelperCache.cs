// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using OpenWebPbx.Phone.Core;
namespace OpenWebPbx.Phone.Windows;
/// <summary>The installer runs outside the installed MSIX so it cannot keep that package in use.</summary>
public static class UpdateHelperCache
{
    private sealed record Member(string Name, long Bytes, string Sha256);
    private sealed record Manifest(int Schema, Member[] Files);
    private static Manifest Read(string root)
    {
        Ordinary(root, true); var path = Path.Combine(root, "updater-files.json"); Ordinary(path, false);
        if (new FileInfo(path).Length is < 20 or > 65536) throw Invalid(); var value = JsonSerializer.Deserialize<Manifest>(File.ReadAllBytes(path)) ?? throw Invalid();
        if (value.Schema != 1 || value.Files.Length is < 5 or > 256 || value.Files.Sum(x => x.Bytes) > 200 * 1024 * 1024 || value.Files.Select(x => x.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != value.Files.Length || !value.Files.Any(x => x.Name == "OpenWebPbx.Phone.Updater.exe")) throw Invalid();
        foreach (var item in value.Files) if (!Regex.IsMatch(item.Name, "^[A-Za-z0-9_.-]{1,160}\\.(dll|exe|json)$") || item.Name.Equals("updater-files.json", StringComparison.OrdinalIgnoreCase) || item.Bytes is < 1 or > 64 * 1024 * 1024 || item.Sha256.Length != 64 || item.Sha256.Any(c => !char.IsAsciiHexDigit(c))) throw Invalid();
        return value;
    }
    private static void Verify(string path, Member item)
    { Ordinary(path, false); using var input = File.OpenRead(path); if (input.Length != item.Bytes || !Convert.ToHexString(SHA256.HashData(input)).Equals(item.Sha256, StringComparison.OrdinalIgnoreCase)) throw Invalid(); }
    public static string Stage(string source, UpdateStorage storage)
    {
        CleanFinished(storage); if (Directory.EnumerateDirectories(storage.Directory, "helper-*").Count() > 2) throw new PhoneInputException("An earlier Windows update helper is still in use. Restart Windows before updating.");
        var manifest = Read(source); var root = Path.Combine(storage.Directory, "helper-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        File.Copy(Path.Combine(source, "updater-files.json"), Path.Combine(root, "updater-files.json"));
        foreach (var item in manifest.Files) { var input = Path.Combine(source, item.Name); Verify(input, item); var target = Path.Combine(root, item.Name); File.Copy(input, target); Verify(target, item); }
        return Path.Combine(root, "OpenWebPbx.Phone.Updater.exe");
    }
    public static void CleanFinished(UpdateStorage storage)
    {
        foreach (var directory in Directory.EnumerateDirectories(storage.Directory, "helper-*"))
        {
            if (!Regex.IsMatch(Path.GetFileName(directory), "^helper-[a-f0-9]{32}$")) continue;
            try
            {
                var manifest = Read(directory); var allowed = manifest.Files.Select(x => x.Name).Append("updater-files.json").ToHashSet(StringComparer.OrdinalIgnoreCase);
                var files = Directory.EnumerateFileSystemEntries(directory).ToArray(); if (files.Any(x => !allowed.Contains(Path.GetFileName(x)))) continue;
                // A still-running helper keeps its executable open. Never kill it or remove its dependencies.
                using (var idle = new FileStream(Path.Combine(directory, "OpenWebPbx.Phone.Updater.exe"), FileMode.Open, FileAccess.Read, FileShare.None)) { }
                foreach (var item in manifest.Files) { var path = Path.Combine(directory, item.Name); try { Verify(path, item); } catch (FileNotFoundException) { } }
                foreach (var file in files) { Ordinary(file, false); File.Delete(file); } Directory.Delete(directory, false);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or PhoneInputException or JsonException) { /* Preserve a running, changed or unavailable owned cache for a later retry. */ }
        }
    }
    private static void Ordinary(string path, bool directory) { var flags = File.GetAttributes(path); if ((flags & FileAttributes.ReparsePoint) != 0 || ((flags & FileAttributes.Directory) != 0) != directory) throw Invalid(); }
    private static PhoneInputException Invalid() => new("The Windows update helper inventory could not be verified. Your current phone has been kept.");
}
