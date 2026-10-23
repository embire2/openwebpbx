// SPDX-License-Identifier: AGPL-3.0-or-later
namespace OpenWebPbx.Phone.Windows;
internal static class StoragePaths
{
    private const string Folder = "OpenWebPBX Free Phone";
    internal static string ForPackage(string family)
    {
        if (family.Length is < 5 or > 150 || family.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-' or '_')) || !new global::Windows.Management.Deployment.PackageManager().FindPackagesForUser("").Any(x => x.Id.FamilyName == family)) throw new InvalidOperationException("The current-user phone package is not installed.");
        return Path.Combine(global::Windows.Management.Core.ApplicationDataManager.CreateForPackageFamily(family).LocalFolder.Path, Folder);
    }
    private static string Parent
    {
        get
        {
            var packaged = false; try { _ = global::Windows.ApplicationModel.Package.Current.Id; packaged = true; } catch { }
            if (packaged) return Path.Combine(global::Windows.Storage.ApplicationData.Current.LocalFolder.Path, Folder);
#if PHONE_PACKAGE_FIXTURE
            var own = new global::Windows.Management.Deployment.PackageManager().FindPackagesForUser("").Single(x => x.Id.Name == OpenWebPbx.Phone.Core.PackageFixture.IdentityName && x.Id.Publisher == OpenWebPbx.Phone.Core.PackageFixture.Publisher);
            return ForPackage(own.Id.FamilyName);
#else
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Folder);
#endif
        }
    }
    internal static string Channel(string channel) => Path.Combine(Parent, channel);
    internal static string Native => Path.Combine(Parent, "native-runtime");
}
