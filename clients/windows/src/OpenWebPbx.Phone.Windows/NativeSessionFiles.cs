// SPDX-License-Identifier: AGPL-3.0-or-later
using System.Security.AccessControl;
using System.Security.Principal;
namespace OpenWebPbx.Phone.Windows;
/// <summary>Private temporary native state; credentials live only in the separate DPAPI profile envelope.</summary>
internal sealed class NativeSessionFiles : IDisposable
{
    public string Path { get; }
    public NativeSessionFiles(
#if PHONE_MEDIA_FIXTURE
        string? fixtureRoot = null
#endif
    )
    {
#if PHONE_MEDIA_FIXTURE
        if (fixtureRoot is not null) { Path = System.IO.Path.Combine(fixtureRoot, "native-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); return; }
#endif
        var parent = StoragePaths.Native;
        for (var item = new DirectoryInfo(parent); item is not null; item = item.Parent) if (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("The private native runtime path is linked.");
        Directory.CreateDirectory(parent); var acl = new DirectorySecurity(); acl.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { WindowsIdentity.GetCurrent().User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) }) acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(parent).SetAccessControl(acl); Path = System.IO.Path.Combine(parent, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path);
    }
    public void Dispose() { if (Directory.Exists(Path) && (File.GetAttributes(Path) & FileAttributes.ReparsePoint) == 0) Directory.Delete(Path, true); }
}
