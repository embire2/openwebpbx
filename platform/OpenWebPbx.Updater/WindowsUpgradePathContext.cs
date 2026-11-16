using System.Security.AccessControl;
using System.Security.Principal;

namespace OpenWebPbx.Updater;

/// <summary>Protected parent authorisation, supplied only by installed/root-owned code.</summary>
public sealed record WindowsUpgradePathContext(string CataloguePath, string LatestFeedPath)
{
    public (byte[] Catalogue, byte[] Latest) Read()
        => (ReadProtected(CataloguePath), ReadProtected(LatestFeedPath));

    public static byte[] ReadProtected(string path)
    {
        if (!Path.IsPathFullyQualified(path) || path.IndexOfAny(['\r', '\n', '\0']) >= 0 ||
            OperatingSystem.IsWindows() && (path.StartsWith("\\\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0))
            throw new InvalidDataException("Use protected local Windows upgrade metadata.");
        var file = new FileInfo(path);
        if (!file.Exists || (file.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
            throw new InvalidDataException("Windows upgrade metadata must be an ordinary protected file.");
        if (OperatingSystem.IsWindows())
        {
            const FileSystemRights writes = FileSystemRights.WriteData | FileSystemRights.AppendData | FileSystemRights.WriteAttributes |
                FileSystemRights.WriteExtendedAttributes | FileSystemRights.Delete | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
            void Check(FileSystemSecurity security)
            {
                foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                    if (rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & writes) != 0 &&
                        rule.IdentityReference.Value is not ("S-1-5-18" or "S-1-5-32-544"))
                        throw new InvalidDataException("Windows upgrade metadata is writable outside Administrators/SYSTEM.");
            }
            Check(file.GetAccessControl(AccessControlSections.Access));
            var parent = file.Directory ?? throw new InvalidDataException("The protected metadata directory is unavailable.");
            if ((parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Linked Windows metadata directories are not allowed.");
            Check(parent.GetAccessControl(AccessControlSections.Access));
        }
        else if ((File.GetUnixFileMode(path) & (UnixFileMode.GroupWrite | UnixFileMode.OtherWrite)) != 0)
            throw new InvalidDataException("Upgrade metadata is writable by another account.");
        return UpdateJson.ReadBytes(path, 262144);
    }
}
