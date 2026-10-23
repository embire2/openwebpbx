// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.Cryptography;
namespace OpenWebPbx.Phone.Core;
public sealed record RuntimeResource(string Path, long Bytes, string Sha256);
public static class RuntimeResources
{
    public static void Verify(string root, IReadOnlyList<RuntimeResource> files)
    {
        if (files.Count is < 1 or > 64 || files.Select(x => x.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != files.Count) throw Invalid();
        var canonical = System.IO.Path.GetFullPath(root); Ordinary(canonical, true);
        foreach (var item in files)
        {
            var parts = item.Path.Split('/');
            if (parts.Length < 2 || parts.Any(p => p is "" or "." or ".." || p.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '_' or '-'))) || item.Bytes is < 1 or > 2 * 1024 * 1024 || item.Sha256.Length != 64 || item.Sha256.Any(c => !char.IsAsciiHexDigit(c))) throw Invalid();
            var target = canonical;
            for (var index = 0; index < parts.Length; index++) { target = System.IO.Path.Combine(target, parts[index]); Ordinary(target, index < parts.Length - 1); }
            if (new FileInfo(target).Length != item.Bytes) throw Invalid();
            using var input = File.OpenRead(target); if (!Convert.ToHexString(SHA256.HashData(input)).Equals(item.Sha256, StringComparison.OrdinalIgnoreCase)) throw Invalid();
        }
    }
    private static void Ordinary(string path, bool directory)
    {
        try { var attributes = File.GetAttributes(path); if ((attributes & FileAttributes.ReparsePoint) != 0 || ((attributes & FileAttributes.Directory) != 0) != directory) throw Invalid(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw Invalid(); }
    }
    private static PhoneInputException Invalid() => new("The phone’s native resources are missing or damaged. Reinstall the official Windows phone package.");
}
