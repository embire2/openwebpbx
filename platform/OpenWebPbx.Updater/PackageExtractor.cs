using System.Formats.Tar;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace OpenWebPbx.Updater;

public static class PackageExtractor
{
    public static async Task<string> Extract(string archive, string destination, VerifiedRelease release, CancellationToken ct)
    {
        await ReleaseVerifier.VerifyArchive(archive, release.Asset, ct);
        if (Directory.Exists(destination)) throw new IOException("The extraction destination already exists.");
        Directory.CreateDirectory(destination);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(destination, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var prefix = $"openwebpbx-{release.Version}-{release.Asset.Platform}";
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total = 0; var files = 0;
        string EntryPath(string name, bool directory, long length)
        {
            if (name.Length > 1024 || name.Contains('\\') || name.Contains(':') || name.IndexOfAny(['\0', '\r', '\n']) >= 0 || name.StartsWith('/') || name.Split('/').Any(x => x is "." or "..")) throw new InvalidDataException("The update archive contains an unsafe path.");
            var clean = name.TrimEnd('/');
            if (clean != prefix && !clean.StartsWith(prefix + "/", StringComparison.Ordinal)) throw new InvalidDataException("The update archive has the wrong platform or version folder.");
            if (!seen.Add(clean) || ++files > 50000 || length < 0 || (total += length) > 12L * 1024 * 1024 * 1024) throw new InvalidDataException("The update archive has duplicate paths or exceeds its limits.");
            var path = Path.GetFullPath(Path.Combine(destination, clean.Replace('/', Path.DirectorySeparatorChar)));
            if (!path.StartsWith(Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new InvalidDataException("The update archive escapes its folder.");
            if (directory) Directory.CreateDirectory(path); else Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            return path;
        }
        async Task Copy(Stream input, string path, long length)
        {
            using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 131072, FileOptions.Asynchronous);
            var buffer = new byte[131072]; long copied = 0;
            while (true) { var count = await input.ReadAsync(buffer, ct); if (count == 0) break; copied += count; if (copied > length) throw new InvalidDataException("An extracted file exceeds its declared size."); await output.WriteAsync(buffer.AsMemory(0, count), ct); }
            if (copied != length) throw new InvalidDataException("An extracted file is incomplete.");
        }
        try
        {
            if (release.Asset.Platform == "windows-x64")
            {
                using var zip = ZipFile.OpenRead(archive);
                foreach (var entry in zip.Entries)
                {
                    ct.ThrowIfCancellationRequested(); var directory = entry.FullName.EndsWith('/');
                    var mode = (entry.ExternalAttributes >> 16) & 0xF000;
                    if ((mode != 0 && mode != 0x8000 && mode != 0x4000) || (entry.ExternalAttributes & 0x400) != 0) throw new InvalidDataException("Archive links and special files are not allowed.");
                    var path = EntryPath(entry.FullName, directory, entry.Length);
                    if (!directory) { using var input = entry.Open(); await Copy(input, path, entry.Length); }
                }
            }
            else
            {
                using var input = File.OpenRead(archive); using var gzip = new GZipStream(input, CompressionMode.Decompress); using var tar = new TarReader(gzip);
                while (await tar.GetNextEntryAsync(copyData: false, cancellationToken: ct) is { } entry)
                {
                    if (entry.EntryType is not (TarEntryType.Directory or TarEntryType.RegularFile or TarEntryType.V7RegularFile)) throw new InvalidDataException("Archive links and special files are not allowed.");
                    var directory = entry.EntryType == TarEntryType.Directory;
                    var path = EntryPath(entry.Name, directory, entry.Length);
                    if (!directory) { if (entry.DataStream is null) throw new InvalidDataException("An archive file has no data."); await Copy(entry.DataStream, path, entry.Length); }
                }
            }
            var package = Path.Combine(destination, prefix);
            await VerifyManifest(package, release.Version, ct);
            return package;
        }
        catch { Directory.Delete(destination, recursive: true); throw; }
    }
    public static async Task VerifyManifest(string package, string version, CancellationToken ct)
    {
        using var document = JsonDocument.Parse(UpdateJson.ReadBytes(Path.Combine(package, "release-manifest.json"), 8 * 1024 * 1024));
        var root = document.RootElement;
        if (root.GetProperty("version").GetString() != version || File.ReadAllText(Path.Combine(package, "VERSION")).Trim() != version) throw new InvalidDataException("The update manifest version is incorrect.");
        var expected = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in root.GetProperty("files").EnumerateObject())
        {
            if (!expected.TryAdd(item.Name, item.Value.GetString()!) || expected.Count > 50000) throw new InvalidDataException("The update manifest has duplicate paths.");
        }
        var actual = Directory.EnumerateFiles(package, "*", SearchOption.AllDirectories).Select(p => Path.GetRelativePath(package, p).Replace('\\', '/')).Where(p => p != "release-manifest.json").ToArray();
        if (actual.Length != expected.Count) throw new InvalidDataException("The update manifest does not list every file.");
        foreach (var relative in actual)
        {
            ct.ThrowIfCancellationRequested();
            if (!expected.TryGetValue(relative, out var hash)) throw new InvalidDataException("The update archive contains an unlisted file.");
            using var file = File.OpenRead(Path.Combine(package, relative));
            if (Convert.ToHexStringLower(await SHA256.HashDataAsync(file, ct)) != hash) throw new InvalidDataException("An extracted update file failed verification.");
        }
        foreach (var required in new[] { "VERSION", "web/resources/require.php", "bootstrap.php" }) if (!expected.ContainsKey(required)) throw new InvalidDataException("The update is missing a required application component.");
        var windows = Directory.Exists(Path.Combine(package, "desktop"));
        foreach (var required in windows ? new[] { "server/OpenWebPbx.Server.exe", "desktop/OpenWebPbx.Desktop.exe" } : new[] { "server/OpenWebPbx.Server", "engine.tar.gz" })
            if (!expected.ContainsKey(required)) throw new InvalidDataException("The update is missing a required native component.");
    }
}
