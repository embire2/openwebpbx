// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using OpenWebPbx.Phone.Core;

namespace OpenWebPbx.Phone.Windows;

/// <summary>Only current-user DPAPI ciphertext is written. No native SDK configuration shares this directory.</summary>
public sealed class ProtectedProfileStore : IProfileStore
{
    private const int Maximum = 2 * 1024 * 1024;
    private readonly string directory, path;
    private readonly SemaphoreSlim gate = new(1, 1);
    private sealed record Envelope(int Schema, Guid? Selected, PhoneProfile[] Profiles);
    public ProtectedProfileStore(string channel)
    {
        if (channel is not ("direct" or "store")) throw new ArgumentException("Choose a supported distribution.");
        directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenWebPBX Free Phone", channel);
        path = Path.Combine(directory, "accounts.dpapi");
    }
    public async Task<IReadOnlyList<PhoneProfile>> ReadAsync(CancellationToken cancellation = default)
    { await gate.WaitAsync(cancellation); try { return Read().Profiles; } finally { gate.Release(); } }
    public async Task<Guid?> SelectedAsync(CancellationToken cancellation = default)
    { await gate.WaitAsync(cancellation); try { return Read().Selected; } finally { gate.Release(); } }
    private Envelope Read()
    {
        EnsurePrivateDirectory(); if (!ExistsStrict(path)) return new(1, null, []);
        Ordinary(path); var size = new FileInfo(path).Length; if (size is < 32 or > Maximum) throw InvalidStore();
        var bytes = Dpapi.Unprotect(File.ReadAllBytes(path));
        try
        {
            var saved = JsonSerializer.Deserialize<Envelope>(bytes) ?? throw InvalidStore();
            if (saved.Schema != 1 || saved.Profiles.Length > 10 || saved.Profiles.Select(x => x.Id).Distinct().Count() != saved.Profiles.Length ||
                (saved.Selected is not null && saved.Profiles.All(x => x.Id != saved.Selected))) throw InvalidStore();
            foreach (var profile in saved.Profiles)
                if (ConnectionRules.Tenant(profile.Server.AbsoluteUri) != profile.Server || profile.Id == Guid.Empty || profile.DeviceId == Guid.Empty) throw InvalidStore();
            return saved;
        }
        catch (JsonException) { throw InvalidStore(); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public async Task SaveAsync(IReadOnlyList<PhoneProfile> profiles, Guid? selected, CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            if (profiles.Count > 10 || profiles.Select(x => x.Id).Distinct().Count() != profiles.Count || (selected is not null && profiles.All(x => x.Id != selected))) throw InvalidStore();
            EnsurePrivateDirectory(); if (ExistsStrict(path)) Ordinary(path);
            var plain = JsonSerializer.SerializeToUtf8Bytes(new Envelope(1, selected, profiles.ToArray())); byte[] sealedBytes;
            try { if (plain.Length > Maximum / 2) throw InvalidStore(); sealedBytes = Dpapi.Protect(plain); }
            finally { CryptographicOperations.ZeroMemory(plain); }
            var temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                { PrivateFile(temporary); file.Write(sealedBytes); file.Flush(true); }
                cancellation.ThrowIfCancellationRequested(); File.Move(temporary, path, true); PrivateFile(path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        finally { gate.Release(); }
    }
    private void EnsurePrivateDirectory()
    {
        for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent)
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0) throw InvalidStore();
        Directory.CreateDirectory(directory);
        var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
        foreach (var sid in Owners()) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(directory).SetAccessControl(acl);
    }
    private static IEnumerable<SecurityIdentifier> Owners() => [WindowsIdentity.GetCurrent().User ?? throw InvalidStore(), new(WellKnownSidType.LocalSystemSid, null)];
    private static void PrivateFile(string value)
    {
        Ordinary(value); var acl = new FileSecurity(); acl.SetAccessRuleProtection(true, false);
        foreach (var sid in Owners()) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(value).SetAccessControl(acl);
    }
    private static bool ExistsStrict(string value) { try { _ = File.GetAttributes(value); return true; } catch (FileNotFoundException) { return false; } }
    private static void Ordinary(string value) { if ((File.GetAttributes(value) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) throw InvalidStore(); }
    private static PhoneInputException InvalidStore() => new("Your saved accounts could not be opened securely. Do not delete the saved file; contact support.");
}

internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static byte[] Protect(byte[] data) => Transform(data, true);
    public static byte[] Unprotect(byte[] data) => Transform(data, false);
    private static byte[] Transform(byte[] data, bool protect)
    {
        var pointer = Marshal.AllocHGlobal(data.Length); var input = new Blob { Length = data.Length, Data = pointer }; var output = new Blob();
        try
        {
            Marshal.Copy(data, 0, pointer, data.Length);
            var ok = protect ? CryptProtectData(ref input, "OpenWebPBX Free Phone", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output) : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok || output.Length is < 1 or > 2 * 1024 * 1024) throw new PhoneInputException("Windows could not protect or unlock your saved accounts.");
            var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            unsafe { CryptographicOperations.ZeroMemory(new Span<byte>((void*)pointer, data.Length)); if (output.Data != IntPtr.Zero) CryptographicOperations.ZeroMemory(new Span<byte>((void*)output.Data, output.Length)); }
            Marshal.FreeHGlobal(pointer); if (output.Data != IntPtr.Zero) LocalFree(output.Data);
        }
    }
}
